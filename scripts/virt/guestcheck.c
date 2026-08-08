/* guestcheck — assert the contracts a hypervisor makes to guest userspace, by
 * exercising them directly rather than waiting for an application to die of
 * one. Two so far, both of which every non-trivial program depends on:
 *
 *   1. CPUID tells the truth — every feature advertised can be executed.
 *   2. Memory permissions are honoured — a page can be made writable, written,
 *      made executable, and executed. That is what every just-in-time compiler
 *      does, which is to say every browser, JVM, .NET and Python runtime.
 *
 * The value is in WHERE the failure is reported. Both contracts are broken
 * silently: the guest kernel does not notice, the application does not know to
 * check, and the fault lands somewhere unrelated in whichever library was
 * running. Asking directly turns that into one line naming the contract.
 *
 * A guest takes CPUID literally. Libraries dispatch on a feature bit and emit
 * that feature's instructions with no second check, because on real hardware
 * there is nothing to check — the bit IS the promise. A hypervisor that
 * advertises a feature it cannot back turns every such library into a landmine,
 * and the resulting fault names nothing useful: it surfaces wherever the
 * dispatch table happened to send control, in a different library on every run.
 *
 * That is not a bug class you find by running applications until one dies. It
 * is found by asking the processor directly, which is all this does: for each
 * feature CPUID advertises, execute one representative instruction from it
 * under a fault handler, and report any that fault. Features CPUID does NOT
 * advertise are executed too — a feature that works while being denied is a
 * lesser fault, but it is still a lie about the machine, and it is free to
 * check while we are here.
 *
 * Builds as a static binary on the host (no libc in the guest image needs to
 * match) and runs anywhere: scripts/virt/build_firefox_guest.sh installs it,
 * and /init runs it before the compositor.
 *
 * Exit status is the verdict: 0 = every contract held, 1 = at least one was
 * broken, 2 = the probe itself could not run.
 */

#include <cpuid.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* The fault trap. A feature that is absent raises #UD (SIGILL); one whose
 * state the hypervisor never enabled can raise #GP (SIGSEGV/SIGBUS instead),
 * so all three are caught — the question is "did it execute", not "how did it
 * fail". */
static sigjmp_buf escape;
static volatile sig_atomic_t faulted;
static volatile int fault_signal;

static void on_fault(int sig)
{
    faulted = 1;
    fault_signal = sig;
    siglongjmp(escape, 1);
}

/* Which CPUID register a feature bit lives in. */
enum reg { REG_EAX, REG_EBX, REG_ECX, REG_EDX };

struct feature {
    const char *name;
    unsigned leaf;
    unsigned subleaf;
    enum reg reg;
    unsigned bit;
    void (*execute)(void);
};

/* One representative instruction per feature. Each is the cheapest encoding
 * that cannot be decoded without the feature, operating only on registers it
 * clobbers explicitly, so a fault is always the decoder's and never an
 * addressing accident. MOVBE is the one exception: it has no register-only
 * form at all, so it reads a local — an invalid encoding would #UD on every
 * processor and report a working feature as broken. */

static void x_sse(void)     { __asm__ volatile("xorps %%xmm0, %%xmm0" ::: "xmm0"); }
static void x_sse2(void)    { __asm__ volatile("xorpd %%xmm0, %%xmm0" ::: "xmm0"); }
static void x_sse3(void)    { __asm__ volatile("haddpd %%xmm0, %%xmm0" ::: "xmm0"); }
static void x_ssse3(void)   { __asm__ volatile("pabsb %%xmm0, %%xmm0" ::: "xmm0"); }
static void x_sse41(void)   { __asm__ volatile("pmaxsd %%xmm0, %%xmm0" ::: "xmm0"); }
static void x_sse42(void)   { __asm__ volatile("crc32l %%eax, %%eax" ::: "eax"); }
static void x_popcnt(void)  { __asm__ volatile("popcntl %%eax, %%eax" ::: "eax", "cc"); }
static void x_aes(void)     { __asm__ volatile("aesenc %%xmm0, %%xmm1" ::: "xmm1"); }
static void x_pclmul(void)  { __asm__ volatile("pclmulqdq $0, %%xmm0, %%xmm1" ::: "xmm1"); }
static void x_avx(void)     { __asm__ volatile("vzeroupper" ::: "memory"); }
static void x_avx2(void)    { __asm__ volatile("vpxor %%ymm0, %%ymm0, %%ymm0" ::: "ymm0"); }
static void x_fma(void)     { __asm__ volatile("vfmadd132ps %%ymm0, %%ymm1, %%ymm2" ::: "ymm2"); }
static void x_f16c(void)    { __asm__ volatile("vcvtph2ps %%xmm0, %%xmm1" ::: "xmm1"); }
static void x_bmi1(void)    { __asm__ volatile("andnl %%eax, %%eax, %%eax" ::: "eax", "cc"); }
static void x_bmi2(void)    { __asm__ volatile("shlxl %%eax, %%eax, %%eax" ::: "eax"); }
static void x_adx(void)     { __asm__ volatile("adcxl %%eax, %%eax" ::: "eax", "cc"); }
static void x_lzcnt(void)   { __asm__ volatile("lzcntl %%eax, %%eax" ::: "eax", "cc"); }
static void x_rdrand(void)  { __asm__ volatile("rdrand %%eax" ::: "eax", "cc"); }
static void x_rdseed(void)  { __asm__ volatile("rdseed %%eax" ::: "eax", "cc"); }
static void x_sha(void)     { __asm__ volatile("sha1msg1 %%xmm0, %%xmm1" ::: "xmm1"); }
static void x_rdtscp(void)  { __asm__ volatile("rdtscp" ::: "eax", "ecx", "edx"); }
static void x_fsgsbase(void){ __asm__ volatile("rdfsbase %%rax" ::: "rax"); }
static void x_xsave(void)   { __asm__ volatile("xgetbv" : : "c"(0) : "eax", "edx"); }
static void x_movbe(void)   { volatile unsigned v = 0; __asm__ volatile("movbe %0, %%eax" : : "m"(v) : "eax"); }
static void x_avx512f(void) { __asm__ volatile("vpxorq %%zmm0, %%zmm0, %%zmm0" ::: "zmm0"); }

/* Leaf and bit as the SDM numbers them, so a row can be checked against the
 * manual without decoding anything here. */
static const struct feature FEATURES[] = {
    { "sse",      1, 0, REG_EDX, 25, x_sse },
    { "sse2",     1, 0, REG_EDX, 26, x_sse2 },
    { "sse3",     1, 0, REG_ECX, 0,  x_sse3 },
    { "pclmul",   1, 0, REG_ECX, 1,  x_pclmul },
    { "ssse3",    1, 0, REG_ECX, 9,  x_ssse3 },
    { "fma",      1, 0, REG_ECX, 12, x_fma },
    { "sse4.1",   1, 0, REG_ECX, 19, x_sse41 },
    { "sse4.2",   1, 0, REG_ECX, 20, x_sse42 },
    { "movbe",    1, 0, REG_ECX, 22, x_movbe },
    { "popcnt",   1, 0, REG_ECX, 23, x_popcnt },
    { "aes",      1, 0, REG_ECX, 25, x_aes },
    { "xsave",    1, 0, REG_ECX, 26, x_xsave },
    { "avx",      1, 0, REG_ECX, 28, x_avx },
    { "f16c",     1, 0, REG_ECX, 29, x_f16c },
    { "rdrand",   1, 0, REG_ECX, 30, x_rdrand },
    { "fsgsbase", 7, 0, REG_EBX, 0,  x_fsgsbase },
    { "bmi1",     7, 0, REG_EBX, 3,  x_bmi1 },
    { "avx2",     7, 0, REG_EBX, 5,  x_avx2 },
    { "bmi2",     7, 0, REG_EBX, 8,  x_bmi2 },
    { "avx512f",  7, 0, REG_EBX, 16, x_avx512f },
    { "rdseed",   7, 0, REG_EBX, 18, x_rdseed },
    { "adx",      7, 0, REG_EBX, 19, x_adx },
    { "sha",      7, 0, REG_EBX, 29, x_sha },
    /* Leaf 8000_0001H: the AMD-numbered extensions Intel also reports. */
    { "lzcnt",    0x80000001, 0, REG_ECX, 5,  x_lzcnt },
    { "rdtscp",   0x80000001, 0, REG_EDX, 27, x_rdtscp },
};

#define FEATURE_COUNT (sizeof FEATURES / sizeof FEATURES[0])

/* Whether CPUID advertises `f`, or -1 when the leaf itself is unavailable. */
static int advertised(const struct feature *f)
{
    unsigned eax, ebx, ecx, edx;
    unsigned max = __get_cpuid_max(f->leaf & 0x80000000u, 0);

    if (f->leaf > max)
        return -1;
    if (!__get_cpuid_count(f->leaf, f->subleaf, &eax, &ebx, &ecx, &edx))
        return -1;
    switch (f->reg) {
    case REG_EAX: return (eax >> f->bit) & 1;
    case REG_EBX: return (ebx >> f->bit) & 1;
    case REG_ECX: return (ecx >> f->bit) & 1;
    default:      return (edx >> f->bit) & 1;
    }
}

/* Run one feature's instruction; 1 if it executed, 0 if it faulted. */
static int executes(const struct feature *f)
{
    faulted = 0;
    fault_signal = 0;
    if (sigsetjmp(escape, 1) == 0)
        f->execute();
    return !faulted;
}

/* A function body that returns 0x2A, in machine code: mov eax, 42; ret. Small
 * enough to be obviously correct, and its return value proves the page really
 * executed rather than merely being reachable. */
static const unsigned char RETURNS_42[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };

/* The just-in-time compiler's contract, which is a hypervisor's paging
 * contract seen from userspace: write instructions into a page, change that
 * page to executable, and execute them. A JIT does this thousands of times a
 * second and flips the permissions BACK to writable to patch the code it
 * already emitted — so the flip is exercised in both directions, because a
 * stale execute-permission mapping fails only on the second pass.
 *
 * `rounds` is what separates a paging bug from a first-time-setup bug: EPT and
 * TLB faults of this kind usually appear once a mapping has been changed and
 * re-changed, not on the first use.
 */
static int jit_contract(int rounds)
{
    long page = sysconf(_SC_PAGESIZE);
    unsigned char *code;
    int (*call)(void);
    int i;

    code = mmap(NULL, (size_t)page, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == MAP_FAILED) {
        printf("guestcheck: BROKEN jit cannot map a writable page\n");
        return 0;
    }
    call = (int (*)(void))code;

    for (i = 0; i < rounds; i++) {
        /* Emit, seal, run — the JIT cycle. The value returned varies per round
         * so a cached translation of the previous round cannot pass for this
         * one: the answer proves THIS round's code ran. Only the low byte of
         * the `mov eax, imm32` is patched, so the expected value is the byte
         * that fits there and nothing wider. */
        int want = i & 0xFF;

        if (mprotect(code, (size_t)page, PROT_READ | PROT_WRITE) != 0) {
            printf("guestcheck: BROKEN jit cannot make an executable page writable again (round %d)\n", i);
            munmap(code, (size_t)page);
            return 0;
        }
        memcpy(code, RETURNS_42, sizeof RETURNS_42);
        code[1] = (unsigned char)want; /* the immediate in `mov eax, imm32` */

        if (mprotect(code, (size_t)page, PROT_READ | PROT_EXEC) != 0) {
            printf("guestcheck: BROKEN jit cannot make a written page executable (round %d)\n", i);
            munmap(code, (size_t)page);
            return 0;
        }

        faulted = 0;
        if (sigsetjmp(escape, 1) == 0) {
            int got = call();
            if (got != want) {
                printf("guestcheck: BROKEN jit page returned %d, expected %d (round %d)"
                       " — a stale translation, not a fault\n", got, want, i);
                munmap(code, (size_t)page);
                return 0;
            }
        }
        if (faulted) {
            printf("guestcheck: BROKEN jit page faulted on execution (signal %d, round %d)\n",
                   fault_signal, i);
            munmap(code, (size_t)page);
            return 0;
        }
    }

    munmap(code, (size_t)page);
    printf("guestcheck: PASS jit %d write/seal/execute rounds\n", rounds);
    return 1;
}

/* How many times the JIT contract is exercised. A permission or translation
 * fault of this kind shows on a re-mapping, not a first mapping, so one round
 * would prove almost nothing; a few hundred costs milliseconds. */
#define JIT_ROUNDS 256

int main(void)
{
    struct sigaction sa;
    int checked = 0, broken = 0, ghosts = 0;

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_fault;
    sa.sa_flags = SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGILL, &sa, NULL) || sigaction(SIGSEGV, &sa, NULL) ||
        sigaction(SIGBUS, &sa, NULL) || sigaction(SIGFPE, &sa, NULL)) {
        printf("guestcheck: cannot install the fault handler\n");
        return 2;
    }

    for (size_t i = 0; i < FEATURE_COUNT; i++) {
        const struct feature *f = &FEATURES[i];
        int claimed = advertised(f);
        int works;

        if (claimed < 0)
            continue;
        works = executes(f);
        checked++;
        if (claimed && !works) {
            /* The fault this whole program exists to catch. */
            printf("guestcheck: BROKEN %s advertised but faults (signal %d)\n",
                   f->name, fault_signal);
            broken++;
        } else if (!claimed && works) {
            printf("guestcheck: ghost %s executes but is not advertised\n", f->name);
            ghosts++;
        }
    }

    if (broken)
        printf("guestcheck: FAIL %d of %d advertised features cannot execute\n",
               broken, checked);
    else
        printf("guestcheck: PASS %d cpu features consistent%s\n", checked,
               ghosts ? " (ghosts listed above)" : "");

    if (!jit_contract(JIT_ROUNDS))
        broken++;

    return broken ? 1 : 0;
}
