/*
 * hydra_fpga_mem_harness.sv -- the whole path, from the serial port
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Host writes matrices into the scratchpad ('M'), dispatches a descriptor
 * carrying the bank addresses through the register map, the crossbar sends
 * it to the array, the streamer feeds it from memory, the results are
 * written back, and the host reads them out ('R').
 *
 * No synthetic operands anywhere in that sentence.
 */
`default_nettype none

module hydra_fpga_mem_harness #(
  parameter int CLKS_PER_BIT = 104,
  parameter int HALF         = 8
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       uart_rx_i,
  output logic       uart_tx_o,
  input  logic [1:0] profile,
  output logic [7:0] uo_mirror,
  output logic [7:0] uio_mirror,
  output logic       reg_mode_o
);
  logic [7:0]  ui_in, ui_sys, uo_out, uio_out, uio_oe;
  logic        tile_rst_n;
  logic        mem_we;
  logic [1:0]  mem_bank;
  logic [15:0] mem_addr, mem_raddr;
  logic [31:0] mem_wdata, mem_rdata;
  logic [31:0] checksum, simd_checksum;
  logic [15:0] tiles, simd_jobs;

  hydra_fpga_bridge #(.CLKS_PER_BIT(CLKS_PER_BIT), .HALF(HALF),
                      .DEFAULT_REG(1'b1)) u_bridge (
    .clk(clk), .rst_n(rst_n), .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
    .ui_in(ui_in), .uo_out(uo_out), .uio_out(uio_out),
    .tile_rst_n(tile_rst_n),
    .mem_we(mem_we), .mem_bank(mem_bank), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_raddr(mem_raddr), .mem_rdata(mem_rdata),
    .reg_mode_o(reg_mode_o));

  always_comb begin
    ui_sys      = ui_in;
    ui_sys[7:6] = profile;
  end

  hydra_sys_tile #(.TPU_FROM_MEM(1'b1)) u_sys (
    .ui_in(ui_sys), .uo_out(uo_out), .uio_in(8'h00), .uio_out(uio_out),
    .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(tile_rst_n),
    .dbg_checksum(checksum), .dbg_tiles(tiles),
    .dbg_simd_checksum(simd_checksum), .dbg_simd_jobs(simd_jobs),
    .mem_we(mem_we), .mem_bank(mem_bank), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_raddr(mem_raddr), .mem_rdata(mem_rdata));

  // Switches up: how many tiles the array has completed, on the lights.
  assign uo_mirror  = (profile == 2'b11) ? tiles[7:0] : uo_out;
  assign uio_mirror = uio_out;
  wire _unused = &{uio_oe, checksum, simd_checksum, simd_jobs, 1'b0};
endmodule

`default_nettype wire
