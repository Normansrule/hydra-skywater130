/*
 * crt0.S -- start-up for bare-metal C on the HYDRA CPU slot (Sixfold RV64)
 *
 * gp and sp, .bss cleared, main() called; its return value r ends the job
 * through TOHOST as (r << 1) | 1, the HTIF convention, so a program that
 * returns 0 reports 1 and every result is nonzero (a zero write would not
 * end the job). A trap (Sixfold takes ecall, ebreak and interrupts) ends it
 * with mcause in the code.
 */
    .section .text.init, "ax"
    .globl _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, _stack_top
    la      t0, trap
    csrw    mtvec, t0
    la      t0, _bss_start
    la      t1, _bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:  call    main
    slli    a0, a0, 1
    ori     a0, a0, 1
    csrw    0x51E, a0          /* TOHOST: the job ends */
3:  j       3b

    .align  2
trap:
    csrr    a0, mcause
    slli    a0, a0, 8
    ori     a0, a0, 0xFF       /* 0x..FF: ended by a trap */
    csrw    0x51E, a0
4:  j       4b
