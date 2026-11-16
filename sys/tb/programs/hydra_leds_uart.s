# =============================================================================
# hydra_leds_uart.s: HYDRA's own program for the CPU slot's pins (v67)
#
# Sets both bytes of the LEDS register and prints three characters, then halts.
# Sixfold's model records the LEDs and the console; make cpu-uart checks the
# CPU wrapper's uart_tx and gpio_out pins against them, and make sky130-mcu
# checks the chip's pads 29 (UART) and 30-43 (LEDs). Assembled by Sixfold's
# own assembler (model/asm.js) through tools/cpu_vectors.mjs.
# EXPECT-OUTPUT: ok\n
# EXPECT: a0 = 7
# =============================================================================
    li   t1, 0x10000000      # the device page: PUTCHAR at +0, LEDS at +8
    li   t0, 0x2A5C
    sh   t0, 8(t1)           # LEDS: both bytes
    li   t2, 111             # 'o'
    sb   t2, 0(t1)
    li   t2, 107             # 'k'
    sb   t2, 0(t1)
    li   t2, 10              # newline
    sb   t2, 0(t1)
    li   a0, 7
    halt
