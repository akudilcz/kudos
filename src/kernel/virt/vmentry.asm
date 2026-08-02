; vmentry.asm — the VM-entry/exit trampoline (Intel SDM Vol 3C §26, §27).
;
; extern fn vmxEnter(regs: *GuestRegs, launched: bool) u64
;   System V: rdi = pointer to the 15-register GuestRegs block, sil = launched?
;   Returns 0 when a VM exit occurred (guest ran and exited); returns the RFLAGS
;   image (always nonzero — bit 1 is fixed 1) when VM entry itself failed.
;
; On entry we save the host callee-saved registers, point the VMCS host RSP/RIP at
; this frame and the exit landing pad, load the guest GPRs, and VMLAUNCH (first
; entry) or VMRESUME (subsequent). A VM exit re-enters at .vmexit with host RSP
; restored by the CPU; we write the guest GPRs back and return 0. A failed entry
; falls through to .vmfail and returns RFLAGS so the caller can read the reason.
;
; GuestRegs field offsets — MUST match the extern struct in vcpu.zig.

%define R_RAX 0x00
%define R_RBX 0x08
%define R_RCX 0x10
%define R_RDX 0x18
%define R_RSI 0x20
%define R_RDI 0x28
%define R_RBP 0x30
%define R_R8  0x38
%define R_R9  0x40
%define R_R10 0x48
%define R_R11 0x50
%define R_R12 0x58
%define R_R13 0x60
%define R_R14 0x68
%define R_R15 0x70

%define VMCS_HOST_RSP 0x6C14
%define VMCS_HOST_RIP 0x6C16

default rel
section .text
global vmxEnter

vmxEnter:
    ; Save host callee-saved registers (System V: rbx, rbp, r12–r15).
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rdi                      ; save the GuestRegs pointer for the exit path

    ; Point the VMCS host state at this stack and the exit landing pad, so a VM
    ; exit returns here with rsp restored to exactly this value.
    mov  rdx, VMCS_HOST_RSP
    vmwrite rdx, rsp
    lea  rax, [.vmexit]
    mov  rdx, VMCS_HOST_RIP
    vmwrite rdx, rax

    ; Decide launch vs resume now, while sil is still the argument. `mov` does not
    ; disturb flags, so ZF survives the guest-register loads below.
    test sil, sil                 ; ZF = 1 when not yet launched

    ; Load the guest GPRs (rdi last, since it holds the pointer we read from).
    mov  rax, [rdi + R_RAX]
    mov  rbx, [rdi + R_RBX]
    mov  rcx, [rdi + R_RCX]
    mov  rbp, [rdi + R_RBP]
    mov  r8,  [rdi + R_R8]
    mov  r9,  [rdi + R_R9]
    mov  r10, [rdi + R_R10]
    mov  r11, [rdi + R_R11]
    mov  r12, [rdi + R_R12]
    mov  r13, [rdi + R_R13]
    mov  r14, [rdi + R_R14]
    mov  r15, [rdi + R_R15]
    mov  rdx, [rdi + R_RDX]
    mov  rsi, [rdi + R_RSI]
    mov  rdi, [rdi + R_RDI]        ; rdi last

    jz   .launch
    vmresume
    jmp  .vmfail
.launch:
    vmlaunch
    jmp  .vmfail

    ; --- VM exit landing pad: the CPU jumps here with guest GPRs live ---
.vmexit:
    push rdi                       ; stash guest rdi; [rsp]=guest_rdi, [rsp+8]=regs ptr
    mov  rdi, [rsp + 8]            ; recover the GuestRegs pointer
    mov  [rdi + R_RAX], rax
    mov  [rdi + R_RBX], rbx
    mov  [rdi + R_RCX], rcx
    mov  [rdi + R_RDX], rdx
    mov  [rdi + R_RSI], rsi
    mov  [rdi + R_RBP], rbp
    mov  [rdi + R_R8],  r8
    mov  [rdi + R_R9],  r9
    mov  [rdi + R_R10], r10
    mov  [rdi + R_R11], r11
    mov  [rdi + R_R12], r12
    mov  [rdi + R_R13], r13
    mov  [rdi + R_R14], r14
    mov  [rdi + R_R15], r15
    pop  rax                       ; guest rdi we stashed
    mov  [rdi + R_RDI], rax
    add  rsp, 8                    ; drop the saved GuestRegs pointer
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    pop  rbp
    xor  eax, eax                  ; 0 = a VM exit occurred
    ret

    ; --- VM-entry failure: guest never ran; return RFLAGS (nonzero) ---
.vmfail:
    pushfq
    pop  rax                       ; RFLAGS image, always nonzero
    add  rsp, 8                    ; drop the saved GuestRegs pointer
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    pop  rbp
    ret
