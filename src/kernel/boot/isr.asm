; isr.asm — 256 interrupt stubs + common entry.
; Each stub pushes a uniform frame and calls the Zig dispatcher isrDispatch.
bits 64

extern isrDispatch
global isr_stub_table

section .text

; Vectors 8,10-14,17,21 push an error code; the rest get a dummy 0 so the
; saved frame layout is uniform.
%macro ISR_NOERR 1
isr_stub_%1:
    push qword 0          ; dummy error code
    push qword %1         ; vector number
    jmp isr_common
%endmacro

%macro ISR_ERR 1
isr_stub_%1:
    push qword %1         ; vector number (error code already on stack)
    jmp isr_common
%endmacro

%assign i 0
%rep 256
  %if i == 8 || i == 10 || i == 11 || i == 12 || i == 13 || i == 14 || i == 17 || i == 21
    ISR_ERR i
  %else
    ISR_NOERR i
  %endif
  %assign i i+1
%endrep

isr_common:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; Save x87+SSE state so an interrupted xmm computation (e.g. the compositor's
    ; SSE2 pixel copies) is not corrupted. The save area is carved from THIS core's
    ; own interrupt stack, not a shared static buffer: on the SMP build every core
    ; takes its own LAPIC-timer/IPI interrupts concurrently, so a single global
    ; buffer would let two cores fxsave over each other and fxrstor the wrong
    ; core's state (silent XMM/MXCSR corruption). A stack-local area is inherently
    ; per-core and per-nesting-level.
    ;
    ; The frame pointer (current rsp) is preserved in rbx (callee-saved, already
    ; pushed above, so isrDispatch will restore it for us). We then align rsp down
    ; to 16 and reserve 512 bytes for FXSAVE (which #GPs on a misaligned operand).
    mov rbx, rsp          ; rbx = &Frame (survives isrDispatch: callee-saved)
    and rsp, -16          ; 16-align for fxsave
    sub rsp, 512          ; reserve the FXSAVE area on this core's stack
    fxsave [rsp]

    mov rdi, rbx          ; arg0 = pointer to the saved frame (not the fxsave area)
    cld
    call isrDispatch

    fxrstor [rsp]
    mov rsp, rbx          ; drop the fxsave area + realignment padding

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16           ; discard vector + error code
    iretq

; Table of stub addresses, read by src/kernel/interrupts/idt.zig.
section .rodata
isr_stub_table:
%assign i 0
%rep 256
    dq isr_stub_ %+ i
%assign i i+1
%endrep

; (The FXSAVE area is carved per-core from each core's own interrupt stack in
; isr_common above — there is NO shared static buffer, which would be an SMP data
; race between concurrent interrupts on different cores.)
