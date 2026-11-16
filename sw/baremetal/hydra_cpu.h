/*
 * hydra_cpu.h -- the HYDRA CPU slot's memory map, for bare-metal C on Sixfold
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * The role chip_config.h plays in a Baremetal-IDE platform folder: every
 * address a program needs, taken from the RTL and the model, not invented.
 *
 *   RAM       0x0000_0000 .. 0x0000_FFFF  64 KiB; on the SkyWater 130 chip the
 *                                         16 KiB of SRAM macros repeat through it
 *                                         (sys/rtl/hydra_cpu_sram.sv)
 *   reset PC  0x0000_2000                 Sixfold's model/core.js RESET_PC; the
 *                                         host may load another entry address
 *   devices   0x1000_0000 .. 0x1000_00FF  model/core.js and
 *                                         sys/rtl/hydra_engine_cpu.sv
 *   TOHOST    CSR 0x51E                   a nonzero write ends the job
 */
#ifndef HYDRA_CPU_H
#define HYDRA_CPU_H
#include <stdint.h>

#define HYDRA_RESET_PC      0x00002000UL
#define HYDRA_RAM_BYTES_CHIP 16384UL          /* 8 SRAM macros of 2 KiB */

#define HYDRA_MMIO_BASE     0x10000000UL
#define HYDRA_PUTCHAR       (*(volatile uint8_t  *)(HYDRA_MMIO_BASE + 0x00))
#define HYDRA_LEDS          (*(volatile uint16_t *)(HYDRA_MMIO_BASE + 0x08))
#define HYDRA_BUTTONS       (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x10))
#define HYDRA_MTIME         (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x58))
#define HYDRA_MTIMECMP      (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x60))

/* The console UART (v67, sys/rtl/hydra_engine_cpu.sv): PUTCHAR queues a byte
 * for an 8N1 transmitter on the uart_tx pin. Sixfold's model has neither
 * register and reads them as 0. */
#define HYDRA_UART_DIV      (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x80))  /* clocks per bit */
#define HYDRA_UART_STATUS   (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x88))
#define HYDRA_UART_BUSY     0x1u
#define HYDRA_UART_FULL     0x2u                 /* a PUTCHAR now would be dropped */

/* The dispatch port (sys/rtl/hydra_engine_cpu.sv): the CPU hands a 128-bit
 * descriptor and a 64-bit ABI v2 header to the scheduler. STATUS reads
 * {tags, completed, dispatched, ..., refusal code, refused, ...}. */
#define HYDRA_DESC_LO       (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x100))
#define HYDRA_DESC_HI       (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x108))
#define HYDRA_HDR           (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x110))
#define HYDRA_SUBMIT        (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x118))
#define HYDRA_STATUS        (*(volatile uint64_t *)(HYDRA_MMIO_BASE + 0x120))

#define HYDRA_CSR_TOHOST    0x51E
#define HYDRA_CSR_CYCLE     0xC00

static inline uint64_t hydra_cycle(void) {
  uint64_t v;
  __asm__ volatile ("csrr %0, 0xC00" : "=r"(v));
  return v;
}

#endif
