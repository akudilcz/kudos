/* Linker script for a .kudos app image. The image is position-independent and
 * loaded at an address unknown at build time, so all VMAs start at 0 and the
 * loader copies the flat bytes wherever it likes. `.entry` is first, so byte 0
 * of the objcopied binary is `_entry`. `.bss` is NOLOAD: it is not stored in
 * the file (keeping code_len small) but is counted into __image_end so the
 * loader knows how much zeroed tail to reserve (mem_len). */
ENTRY(_entry)

SECTIONS {
  . = 0;

  .entry : { KEEP(*(.entry)) }
  .text : { *(.text*) }
  .rodata : { *(.rodata*) *(.rodata.*) }
  .data : { *(.data*) *(.data.*) *(.got) *(.got.plt) }

  . = ALIGN(16);
  __data_end = .;

  .bss (NOLOAD) : { *(.bss*) *(COMMON) }

  . = ALIGN(16);
  __image_end = .;

  /DISCARD/ : {
    *(.eh_frame*)
    *(.comment)
    *(.note*)
    *(.debug*)
    *(.riscv.attributes)
  }
}
