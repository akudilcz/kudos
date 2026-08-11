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
    /* A PIE link emits ALLOCATED dynamic-linking metadata (.dynsym, .hash,
     * .dynstr and friends). Nothing ever dynamically links a .kudos image, but
     * a section this script does not NAME is an orphan the linker places
     * wherever it likes — and it likes the front, ahead of `.entry`. That moves
     * the code off byte 0 while every other check still passes, so the loader
     * jumps into a symbol table and the app dies with a wild instruction
     * pointer. Whether the metadata exists at all depends on the program, which
     * is why it struck one app and not the next. Named here so it is dropped,
     * not placed. */
    *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash) *(.dynamic) *(.gnu.version*)
    *(.eh_frame*)
    *(.comment)
    *(.note*)
    *(.debug*)
    *(.riscv.attributes)
  }
}
