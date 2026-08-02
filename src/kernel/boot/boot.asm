; boot.asm — multiboot2 header + 32-bit trampoline into 64-bit long mode.
; The boot chain is described in the comments below, step by step.

MB2_MAGIC      equ 0xe85250d6
MB2_ARCH       equ 0                  ; i386 32-bit protected mode
MB2_BOOT_MAGIC equ 0x36d76289        ; value GRUB leaves in eax

; -----------------------------------------------------------------------------
; Multiboot2 header — must be in the first 32 KiB, 8-byte aligned.
; -----------------------------------------------------------------------------
section .multiboot_header
align 8
header_start:
    dd MB2_MAGIC
    dd MB2_ARCH
    dd header_end - header_start
    dd 0x100000000 - (MB2_MAGIC + MB2_ARCH + (header_end - header_start))

    ; framebuffer request tag (type 5): width, height, depth.
    ; width=0 / height=0 means "no preference" (multiboot2 spec), so GRUB/firmware
    ; hands us the display's NATIVE mode. Requesting a fixed size (e.g. 2560x1440)
    ; breaks real hardware: UEFI GOP/VBE often has no exactly-matching mode and
    ; GRUB falls back to a small default, giving a low-res screen on a large
    ; monitor. Native mode is what we want everywhere; the kernel adapts to
    ; whatever mode GRUB reports.
    ;
    ; This tag makes GRUB program a LINEAR framebuffer before handoff — the normal
    ; (emulated-VGA / real-firmware) display path. Under 4090 passthrough the
    ; guest is booted with NO emulated VGA (-vga none, -machine graphics=off; see
    ; scripts/vm/run.sh), so GRUB has no display device to program a mode on and hands
    ; over NO framebuffer tag regardless — the kernel then falls back to a virtual
    ; framebuffer mirrored onto the 4090 by the GPU path (src/main_root.zig). So this
    ; tag is safe to keep enabled for BOTH paths; it must NOT be disabled, or a
    ; normal boot gets GRUB's default 80x25 TEXT mode (fb_type 2) instead of a
    ; linear framebuffer.
    align 8
    dw 5
    dw 0
    dd 20
    dd 0                       ; width  = 0 -> firmware native
    dd 0                       ; height = 0 -> firmware native
    dd 32                      ; depth: 32 bpp

    ; end tag (type 0)
    align 8
    dw 0
    dw 0
    dd 8
header_end:

; -----------------------------------------------------------------------------
; Page tables and stack (zeroed by GRUB as NOBITS, then filled below).
; -----------------------------------------------------------------------------
section .bss
alignb 4096
p4_table:  resb 4096                  ; PML4
; PDPT exported so the kernel can flip the framebuffer's 1 GiB entry to
; write-combining at runtime (src/kernel/cpu/cpu.zig).
global p3_table
p3_table:  resb 4096                  ; PDPT
p2_tables: resb 4096 * 4              ; 4 page directories -> 4 GiB of 2 MiB pages

; Boot stack. It grows DOWN from stack_top; an overflow runs off the low end
; (stack_bottom) into whatever .bss precedes it — which is p2_tables, the LIVE
; page directories. There is no guard page (RAM is identity-mapped in 2 MiB
; pages) and stack_protector is off (build.zig), so a silent overflow used to
; corrupt active PDEs and wedge the CPU with no panic and no netdebug (it took a
; hardware bisect to find: the plane-blend struct growth pushed disp.bringUp's
; frame over the old 16 KiB).
; Two defences:
;   1. STACK_GUARD — a dead page-aligned gap between the page tables and the
;      stack. A moderate overflow lands here (harmless zeroed .bss) instead of
;      on p2_tables, so the machine keeps running long enough to fault visibly
;      rather than corrupting the address space in silence.
;   2. A generous 64 KiB stack — the native GPU bring-up (opengl.bootAtInit →
;      disp.bringUp) runs on THIS stack (main.zig) with several by-value [4]Head
;      copies live at once; 16 KiB was too tight. A comptime @sizeOf cap in
;      disp.zig keeps the frame from silently regrowing past this budget.
;   (2026-07-11 update: 64 KiB -> 256 KiB and the guard 4 KiB -> 16 KiB.
;   The model loader runs on THIS stack in the single-core session loop, and
;   std.compress's ~75 KiB Decompressor materialized a stack temporary that
;   overflowed 64 KiB straight through the old one-page guard into p2_tables
;   — triple fault, no panic. The temporary itself is fixed (gl/png.zig
;   constructs field-wise into the heap); the bigger stack + guard is the
;   defence-in-depth so the next oversized frame faults visibly instead.)
alignb 4096
stack_guard: resb 16384                ; overflow catch gap (see above)
alignb 16
stack_bottom: resb 262144              ; 256 KiB — see STACK note above
stack_top:

; -----------------------------------------------------------------------------
; 32-bit entry: GRUB jumps here in protected mode, paging off.
; -----------------------------------------------------------------------------
section .boot exec
bits 32
global _start
_start:
    mov esp, stack_top
    mov edi, ebx                      ; multiboot2 info pointer -> SysV arg 0

    cmp eax, MB2_BOOT_MAGIC
    jne .hang

    ; --- PML4[0] -> PDPT ---
    mov eax, p3_table
    or  eax, 0b11                     ; present | writable
    mov [p4_table], eax

    ; Identity-map a large physical range so the framebuffer is reachable
    ; wherever firmware put its BAR (on real HW it can be mapped above 4 GiB).
    ; Prefer 1 GiB pages (512 GiB map) when the CPU supports them; else fall
    ; back to 2 MiB pages over the low 4 GiB.
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 26                 ; CPUID.80000001h:EDX.PDPE1GB
    jz  .map_2mb

    ; --- 1 GiB pages: PDPT[i] = (i<<30) | present|writable|PS, i = 0..511 ---
    mov ecx, 0
.map_1gb:
    mov eax, ecx
    and eax, 3
    shl eax, 30                       ; low dword: (i & 3) << 30
    or  eax, 0b10000011               ; present | writable | huge (PS)
    mov [p3_table + ecx*8], eax
    mov eax, ecx
    shr eax, 2                        ; high dword: i >> 2
    mov [p3_table + ecx*8 + 4], eax
    inc ecx
    cmp ecx, 512
    jb  .map_1gb
    jmp .paging_done

.map_2mb:
    ; --- PDPT[i] -> p2_tables[i], i = 0..3 ---
    mov ecx, 0
.fill_p3:
    mov eax, 4096
    mul ecx                           ; eax = 4096 * i  (edx clobbered)
    add eax, p2_tables
    or  eax, 0b11
    mov [p3_table + ecx*8], eax
    mov dword [p3_table + ecx*8 + 4], 0
    inc ecx
    cmp ecx, 4
    jb  .fill_p3

    ; --- PD entries: 2048 huge pages of 2 MiB = 4 GiB ---
    mov ecx, 0
.fill_p2:
    mov eax, 0x200000
    mul ecx                           ; eax = 2 MiB * i  (< 4 GiB, fits in 32 bits)
    or  eax, 0b10000011               ; present | writable | huge (PS)
    mov [p2_tables + ecx*8], eax
    mov dword [p2_tables + ecx*8 + 4], 0
    inc ecx
    cmp ecx, 2048
    jb  .fill_p2

.paging_done:
    ; --- load CR3 ---
    mov eax, p4_table
    mov cr3, eax

    ; --- enable PAE (CR4.PAE) ---
    mov eax, cr4
    or  eax, 1 << 5
    mov cr4, eax

    ; --- set Long Mode Enable in EFER MSR ---
    mov ecx, 0xC0000080
    rdmsr
    or  eax, 1 << 8
    wrmsr

    ; --- enable paging (CR0.PG); PE is already set by GRUB ---
    mov eax, cr0
    or  eax, 1 << 31
    mov cr0, eax

    ; --- enter long mode ---
    lgdt [gdt64.pointer]
    jmp gdt64.code:long_mode_start

.hang:
    cli
    hlt
    jmp .hang

; -----------------------------------------------------------------------------
; 64-bit GDT: null, code, data.
; -----------------------------------------------------------------------------
section .rodata
align 8
gdt64:
    dq 0                                                  ; null descriptor
.code: equ $ - gdt64
    dq (1<<43) | (1<<44) | (1<<47) | (1<<53)              ; exec, S, present, long
.data: equ $ - gdt64
    dq (1<<41) | (1<<44) | (1<<47)                        ; writable, S, present
.pointer:
    dw $ - gdt64 - 1
    dq gdt64

; -----------------------------------------------------------------------------
; 64-bit entry.
; -----------------------------------------------------------------------------
section .text
bits 64
extern kmain
long_mode_start:
    mov ax, gdt64.data
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    ; --- enable SSE/SSE2 before any SSE instruction runs in kmain ---
    ; (SSE2 is x86-64 baseline; the build enables it, so kmain may emit xmm
    ;  stores immediately. CR0.EM=0, CR0.MP=1, CR4.OSFXSR=1, CR4.OSXMMEXCPT=1.)
    mov rax, cr0
    and ax, 0xFFFB                    ; clear CR0.EM (bit 2) — no x87 emulation
    or  ax, 0x0002                    ; set   CR0.MP (bit 1) — monitor coprocessor
    mov cr0, rax
    mov rax, cr4
    or  rax, (1 << 9) | (1 << 10)     ; CR4.OSFXSR | CR4.OSXMMEXCPT
    mov cr4, rax

    ; edi (zero-extended into rdi) still holds the multiboot2 info pointer.
    call kmain
.hang:
    cli
    hlt
    jmp .hang
