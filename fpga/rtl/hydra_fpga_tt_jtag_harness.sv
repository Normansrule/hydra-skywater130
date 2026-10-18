/*
 * hydra_fpga_tt_jtag_harness.sv -- the TT-A tile with two host paths
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * hydra_fpga_tt_harness plus the JTAG test port: the same bridge, the same
 * tile, and a second host that reaches the bridge's command set over four
 * probe pins (hydra_fpga_jtag_host). Either host works with the other one
 * absent. Built for the Basys 3 first (plans/basys3.yaml), where the
 * on-board FTDI channel carries the serial port and a JTAG probe plugs into
 * Pmod JA.
 */
`default_nettype none

module hydra_fpga_tt_jtag_harness #(
  parameter int CLKS_PER_BIT = 104,
  parameter int HALF         = 8,
  parameter bit DEFAULT_REG  = 1'b1
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       uart_rx_i,
  output logic       uart_tx_o,
  input  logic       jtag_tck,
  input  logic       jtag_tms,
  input  logic       jtag_tdi,
  output logic       jtag_tdo,
  output logic [7:0] uo_mirror,
  output logic [7:0] uio_mirror,
  output logic       reg_mode_o
);
  logic [7:0] ui_in, uo_out, uio_out, uio_oe;
  logic       tile_rst_n;
  logic       jb_rx_v, jb_tx_v, jb_tx_full;
  logic [7:0] jb_rx_d, jb_tx_d;
  logic       tdo_oe;

  hydra_fpga_jtag_host u_jtag (
    .tck(jtag_tck), .tms(jtag_tms), .tdi(jtag_tdi), .tdo(jtag_tdo), .tdo_oe(tdo_oe),
    .clk(clk), .rst_n(rst_n),
    .jb_rx_v(jb_rx_v), .jb_rx_d(jb_rx_d),
    .jb_tx_v(jb_tx_v), .jb_tx_d(jb_tx_d), .jb_tx_full(jb_tx_full));

  hydra_fpga_bridge #(.CLKS_PER_BIT(CLKS_PER_BIT), .HALF(HALF),
                      .DEFAULT_REG(DEFAULT_REG), .HAS_JTAG(1'b1)) u_bridge (
    .clk(clk), .rst_n(rst_n), .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
    .ui_in(ui_in), .uo_out(uo_out), .uio_out(uio_out),
    .tile_rst_n(tile_rst_n),
    // the tile has no operand memory: the port is left unconnected
    .mem_we(), .mem_bank(), .mem_addr(), .mem_wdata(), .mem_raddr(),
    .mem_rdata(32'h0), .mem_refused(1'b0),
    .jb_rx_v(jb_rx_v), .jb_rx_d(jb_rx_d),
    .jb_tx_v(jb_tx_v), .jb_tx_d(jb_tx_d), .jb_tx_full(jb_tx_full),
    .reg_mode_o(reg_mode_o));

  hydra_mom_pins u_tile (
    .ui_in(ui_in), .uo_out(uo_out), .uio_in(8'h00), .uio_out(uio_out),
    .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(tile_rst_n));

  assign uo_mirror  = uo_out;
  assign uio_mirror = uio_out;
  // TDO is driven continuously: the Pmod cable is point to point
  wire _unused = &{uio_oe, tdo_oe, 1'b0};
endmodule

`default_nettype wire
