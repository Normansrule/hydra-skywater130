/*
 * hydra_fpga_tt_harness.sv -- the TT-A tile on an FPGA board, driven from a PC
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Thin: hydra_fpga_bridge does the talking, this only attaches the tile.
 * See hydra_fpga_sys_harness.sv for the same bridge attached to the
 * dispatcher, the crossbar and hardware engines.
 */
`default_nettype none

module hydra_fpga_tt_harness #(
  parameter int CLKS_PER_BIT = 104,
  parameter int HALF         = 8,
  parameter bit DEFAULT_REG  = 1'b1
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       uart_rx_i,
  output logic       uart_tx_o,
  output logic [7:0] uo_mirror,
  output logic [7:0] uio_mirror,
  output logic       reg_mode_o
);
  logic [7:0] ui_in, uo_out, uio_out, uio_oe;
  logic       tile_rst_n;

  hydra_fpga_bridge #(.CLKS_PER_BIT(CLKS_PER_BIT), .HALF(HALF),
                      .DEFAULT_REG(DEFAULT_REG)) u_bridge (
    .clk(clk), .rst_n(rst_n), .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
    .ui_in(ui_in), .uo_out(uo_out), .uio_out(uio_out),
    .tile_rst_n(tile_rst_n),
    // the tile has no operand memory: the port is left unconnected
    .mem_we(), .mem_bank(), .mem_addr(), .mem_wdata(), .mem_raddr(),
    .mem_rdata(32'h0),
    .reg_mode_o(reg_mode_o));

  tt_um_hydra_mom u_tile (
    .ui_in(ui_in), .uo_out(uo_out), .uio_in(8'h00), .uio_out(uio_out),
    .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(tile_rst_n));

  assign uo_mirror  = uo_out;
  assign uio_mirror = uio_out;
  wire _unused = &{uio_oe, 1'b0};
endmodule

`default_nettype wire
