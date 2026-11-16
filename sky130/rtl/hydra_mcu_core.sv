/*
 * hydra_mcu_core.sv -- the microcontroller's core, as one hardened macro
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * The system tile in the configuration hydra_openframe_top uses with MCU = 1
 * (scheduler, Sixfold CPU on eight SkyWater 130 SRAM macros with secure boot,
 * TPU, vector unit), with the macros real. This is the block the OpenFrame
 * chip's first harden places and routes (sky130/harden/mcu_core); the pads,
 * the pad multiplexer and the I2C target stay in the top.
 *
 * BOOT_GOLDEN is the SHA-256 of the one image this mask will run. The harden
 * uses a placeholder: the comparator is the same logic whatever the constant.
 */
`default_nettype none

module hydra_mcu_core #(
  parameter logic [255:0] BOOT_GOLDEN = 256'h0
) (
`ifdef USE_POWER_PINS
  inout  wire        vccd1,
  inout  wire        vssd1,
`endif
  input  wire        clk,
  input  wire        rst_n,
  input  wire [7:0]  ui_in,
  output wire [7:0]  uo_out,
  input  wire [7:0]  uio_in,
  output wire [7:0]  uio_out,
  output wire [7:0]  uio_oe,
  input  wire        mem_we,
  input  wire [1:0]  mem_bank,
  input  wire [15:0] mem_addr,
  input  wire [31:0] mem_wdata,
  input  wire [15:0] mem_raddr,
  output wire [31:0] mem_rdata,
  output wire        mem_refused,
  output wire        cpu_uart_tx,       // the CPU's console UART (v67)
  output wire [15:0] cpu_gpio_out,      // its LEDS register
  input  wire [15:0] cpu_gpio_in        // its BUTTONS register
);
  wire [31:0] dbg_ck, dbg_sck;
  wire [15:0] dbg_t, dbg_sj;

  hydra_sys_tile #(
    .NENG(5), .TPU_ENGINE(1), .SIMD_ENGINE(1), .ABI_V2(1), .CPU_ENGINE(1),
    .SECURE_BOOT(1), .BOOT_GOLDEN(BOOT_GOLDEN),
    .CPU_CACHED(1), .CPU_SRAM(1), .CPU_SRAM_MODEL(0), .CPU_MEM_BYTES(16384), .CPU_CACHE_SETS(16)
  ) u_sys (
    .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
    .ena(1'b1), .clk(clk), .rst_n(rst_n),
    .dbg_checksum(dbg_ck), .dbg_tiles(dbg_t), .dbg_simd_checksum(dbg_sck), .dbg_simd_jobs(dbg_sj),
    .mem_we(mem_we), .mem_bank(mem_bank), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
    .mem_raddr(mem_raddr), .mem_rdata(mem_rdata), .mem_refused(mem_refused),
    .cpu_uart_tx(cpu_uart_tx), .cpu_gpio_out(cpu_gpio_out), .cpu_gpio_in(cpu_gpio_in));

  wire _unused = &{1'b0, dbg_ck, dbg_t, dbg_sck, dbg_sj};
endmodule

`default_nettype wire
