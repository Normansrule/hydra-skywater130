/*
 * link.ld -- bare-metal link for the HYDRA CPU slot (Sixfold RV64)
 *
 * Everything sits in the first 16 KiB, so one image runs on every build: the
 * 64 KiB simulation memory and the chip's 16 KiB of SRAM macros, which repeat
 * through the 64 KiB space. Code starts at Sixfold's reset PC, 0x2000; the
 * stack grows down from the top of the 16 KiB. There is no flash: the host
 * loads the whole image into RAM, so .data needs no copy.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x2000, LENGTH = 0x2000   /* 0x2000 .. 0x3FFF */
}

_stack_size = 0x800;

SECTIONS
{
  .text : {
    KEEP(*(.text.init))
    *(.text .text.*)
  } > RAM
  .rodata : ALIGN(8) { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data : ALIGN(8) {
    *(.data .data.*)
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } > RAM
  .bss (NOLOAD) : ALIGN(8) {
    _bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(8);
    _bss_end = .;
  } > RAM
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
  ASSERT(_bss_end + _stack_size <= _stack_top, "image and stack do not fit in 0x2000..0x3FFF")
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
