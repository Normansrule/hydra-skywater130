/*
 * hydra_fpga_sys_harness.sv -- dispatcher + crossbar + engines, on a board
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Same bridge as the tile harness, different design behind it: here the
 * crossbar and hardware engines close the calibration loop with no host in
 * it. tools/hydra_host.py drives it unchanged -- the register map is the
 * same -- except that COMP writes are ignored, because the engines complete
 * their own work (see hydra_sys_tile.sv).
 */
`default_nettype none

module hydra_fpga_sys_harness #(
  parameter int CLKS_PER_BIT = 104,
  parameter int HALF         = 8,
  parameter int LAT_FAST     = 30,
  parameter int LAT_SLOW     = 2000
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       uart_rx_i,
  output logic       uart_tx_o,
  input  logic [1:0] profile,        // engine latency profile, live
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

  // The system tile reads its latency profile from ui_in[7:6]; the bridge
  // drives those low outside reset, so the board switches supply them.
  always_comb begin
    ui_sys        = ui_in;
    ui_sys[7:6]   = profile;
  end

  hydra_sys_tile #(.LAT_FAST(LAT_FAST), .LAT_SLOW(LAT_SLOW)) u_sys (
    .ui_in(ui_sys), .uo_out(uo_out), .uio_in(8'h00), .uio_out(uio_out),
    .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(tile_rst_n));

  assign uo_mirror  = uo_out;
  assign uio_mirror = uio_out;
  wire _unused = &{uio_oe, 1'b0};
endmodule

`default_nettype wire
