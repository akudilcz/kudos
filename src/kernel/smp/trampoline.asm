; trampoline.asm — Application Processor (AP) startup trampoline.
;
; An AP woken by SIPI begins in 16-bit real mode at CS=(vector<<8), IP=0, i.e.
; physical (vector<<12). The BSP copies this blob to a fixed page-aligned address
; below 1 MiB (TRAMPOLINE_BASE) and SIPIs the vector for that page, so every
; absolute reference here is resolved against that fixed base — the blob is
; assembled `org TRAMPOLINE_BASE` (nasm -f bin) and copied there verbatim.
;
; The trampoline replicates boot.asm's BSP long-mode path but from real mode:
; real16 -> protected32 (CR0.PE) -> load the SAME PML4 the BSP built (shared
; kernel page tables) -> PAE -> EFER.LME -> CR0.PG -> long64 -> enable SSE ->
; load this AP's own stack and jump to the Zig AP entry.
;
; LAYOUT: the handoff block sits at a FIXED offset (HANDOFF_OFF) from the base so
; src/kernel/smp/smp.zig can address each field as TRAMPOLINE_BASE + HANDOFF_OFF + n
; without parsing symbols. smp.zig comptime-asserts the embedded blob's SIZE
; equals HANDOFF_OFF + the handoff block — so if either side moves HANDOFF_OFF
; (or grows the block) without the other, the build fails.

TRAMPOLINE_BASE equ 0x8000
HANDOFF_OFF     equ 0x0F00      ; handoff block, well past the code below

bits 16
org TRAMPOLINE_BASE

; Handoff field absolute addresses (the BSP fills these before each SIPI).
HAND_CR3   equ TRAMPOLINE_BASE + HANDOFF_OFF + 0x00   ; dq: BSP PML4 physical
HAND_STACK equ TRAMPOLINE_BASE + HANDOFF_OFF + 0x08   ; dq: this AP's stack top
HAND_ENTRY equ TRAMPOLINE_BASE + HANDOFF_OFF + 0x10   ; dq: 64-bit apEntry
HAND_ALIVE equ TRAMPOLINE_BASE + HANDOFF_OFF + 0x18   ; dd: AP sets 1 when alive

trampoline_start:
    cli
    cld

    ; Load our own GDT (absolute address, valid because org == load base).
    lgdt [tramp_gdt32.pointer]

    ; Enter 32-bit protected mode: CR0.PE = 1.
    mov eax, cr0
    or  eax, 1
    mov cr0, eax

    ; Far-jump to flush the prefetch queue and load a 32-bit code segment.
    jmp dword 0x08:prot32

; -----------------------------------------------------------------------------
bits 32
prot32:
    ; Reload data segments with the 32-bit data selector.
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; Load CR3 with the BSP's PML4 (shared kernel page tables).
    mov eax, [HAND_CR3]
    mov cr3, eax

    ; Enable PAE (CR4.PAE).
    mov eax, cr4
    or  eax, 1 << 5
    mov cr4, eax

    ; Set EFER.LME (Long Mode Enable), MSR 0xC0000080 bit 8.
    mov ecx, 0xC0000080
    rdmsr
    or  eax, 1 << 8
    wrmsr

    ; Enable paging (CR0.PG); PE already set above.
    mov eax, cr0
    or  eax, 1 << 31
    mov cr0, eax

    ; Load a 64-bit GDT and far-jump to a 64-bit code segment.
    lgdt [tramp_gdt64.pointer]
    jmp 0x08:long64

; -----------------------------------------------------------------------------
bits 64
long64:
    mov ax, 0x10
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    ; Enable SSE/SSE2 exactly as boot.asm does for the BSP (the kernel emits xmm
    ; stores; without this an AP would #UD). CR0.EM=0, CR0.MP=1, CR4.OSFXSR=1,
    ; CR4.OSXMMEXCPT=1.
    mov rax, cr0
    and ax, 0xFFFB
    or  ax, 0x0002
    mov cr0, rax
    mov rax, cr4
    or  rax, (1 << 9) | (1 << 10)
    mov cr4, rax

    ; Load this AP's own stack (heap-allocated by the BSP), and read the entry
    ; pointer — the LAST handoff fields this AP consumes (CR3 was read in prot32).
    mov rsp, [HAND_STACK]
    mov rax, [HAND_ENTRY]

    ; Signal "alive" to the BSP ONLY NOW, after every handoff field has been
    ; consumed: the BSP treats alive==1 as "slot reusable" and immediately
    ; rewrites the block for the next AP. Setting alive before the HAND_ENTRY
    ; read would let that rewrite race our read. x86-TSO keeps this load→store
    ; order (loads are never reordered past later stores), so no fence is needed.
    mov dword [HAND_ALIVE], 1

    ; Jump to the Zig AP entry (src/kernel/smp/smp.zig:apEntry). Takes no args.
    call rax

.hang:
    cli
    hlt
    jmp .hang

; -----------------------------------------------------------------------------
; GDTs embedded in the blob (absolute addresses thanks to `org`).
; -----------------------------------------------------------------------------
align 8
tramp_gdt32:
    dq 0                                            ; null
    dq 0x00CF9A000000FFFF                           ; 32-bit code: base0 limit4G exec
    dq 0x00CF92000000FFFF                           ; 32-bit data: base0 limit4G rw
.pointer:
    dw $ - tramp_gdt32 - 1
    dd tramp_gdt32

align 8
tramp_gdt64:
    dq 0                                            ; null
    dq (1<<43) | (1<<44) | (1<<47) | (1<<53)        ; 64-bit code (exec, S, present, long)
    dq (1<<41) | (1<<44) | (1<<47)                  ; 64-bit data (writable, S, present)
.pointer:
    dw $ - tramp_gdt64 - 1
    dq tramp_gdt64

; Pad up to the handoff block so HANDOFF_OFF is exact regardless of code size.
times (HANDOFF_OFF - ($ - trampoline_start)) db 0

handoff:
    dq 0        ; +0x00 HAND_CR3
    dq 0        ; +0x08 HAND_STACK
    dq 0        ; +0x10 HAND_ENTRY
    dd 0        ; +0x18 HAND_ALIVE
    dd 0        ; +0x1C pad

trampoline_end:
