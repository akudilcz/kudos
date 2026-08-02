/* Kernel link script. */
ENTRY(_start)

SECTIONS {
    . = 1M;
    __kernel_start = .;

    /* Multiboot2 header must come first (within the first 32 KiB). */
    .multiboot_header : {
        KEEP(*(.multiboot_header))
    }

    .boot : {
        *(.boot)
    }

    .text : {
        *(.text*)
    }

    .rodata : {
        *(.rodata*)
    }

    .data : {
        *(.data*)
    }

    /* Page tables at the head of .bss must be page-aligned. */
    . = ALIGN(4096);
    .bss : {
        *(.bss*)
        *(COMMON)
    }

    __kernel_end = .;
}
