/*
 * hydra_fpga_two_harness.sv -- dispatcher with BOTH real engines
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Same bridge, same register map; engine 2 is the systolic array instead of
 * a latency model. Retune its cost row over the serial port (PARAM, setup
 * cost 64 -> 2) and the dispatcher starts sending matrix multiplies to real
 * hardware. Operands come from the adapter's pattern generator until a
 * direct memory access engine exists.
 */
`default_nettype none

module hydra_fpga_two_harness #(
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
  logic [7:0] ui_in, ui_sys, uo_out, uio_out, uio_oe;
  logic       tile_rst_n;

  hydra_fpga_bridge #(.CLKS_PER_BIT(CLKS_PER_BIT), .HALF(HALF),
                      .DEFAULT_REG(1'b1)) u_bridge (
    .clk(clk), .rst_n(rst_n), .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
    .ui_in(ui_in), .uo_out(uo_out), .uio_out(uio_out),
    .tile_rst_n(tile_rst_n),
    .mem_we(), .mem_bank(), .mem_addr(), .mem_wdata(), .mem_raddr(),
    .mem_rdata(32'h0),
    .reg_mode_o(reg_mode_o));

  always_comb begin
    ui_sys      = ui_in;
    ui_sys[7:6] = profile;
  end

  wire [31:0] checksum, simd_checksum;
  wire [15:0] tiles, simd_jobs;

  hydra_sys_tile #(.REAL_TPU(1'b1), .REAL_SIMD(1'b1)) u_sys (
    .ui_in(ui_sys), .uo_out(uo_out), .uio_in(8'h00), .uio_out(uio_out),
    .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(tile_rst_n),
    .dbg_checksum(checksum), .dbg_tiles(tiles),
    .dbg_simd_checksum(simd_checksum), .dbg_simd_jobs(simd_jobs));

  // The switches choose what the lights show. Every checksum must reach a
  // pin or synthesis deletes the engine behind it -- that is how the first
  // "TPU image" ended up with no multipliers in it.
  //   00, 01  status byte
  //   10      vector unit checksum
  //   11      array checksum
  assign uo_mirror  = (profile == 2'b11) ? checksum[7:0] :
                      (profile == 2'b10) ? simd_checksum[7:0] : uo_out;
  assign uio_mirror = (profile == 2'b11) ? tiles[7:0] :
                      (profile == 2'b10) ? simd_jobs[7:0] : uio_out;
  wire _unused = &{uio_oe, 1'b0};
endmodule

`default_nettype wire
