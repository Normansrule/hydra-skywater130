/*
 * hydra_fpga_jtag_host.sv -- the bridge's command set, reached over JTAG
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * A SECOND WAY IN, WITH NOTHING SHARED BUT THE COMMANDS
 * ===========================================================================
 * The serial port and this port both speak hydra_fpga_bridge's command set
 * (A5 SPI frame, C3 reset, 96/97 pins, ...). They share no clock, no pin and
 * no state machine below the bridge's command decoder: a dead UART, a wrong
 * baud divisor or a stuck receive line leaves this path working, and a
 * probe that cannot clock leaves the serial path working.
 *
 * The pieces are the ones dbg/ already verified, unchanged:
 *
 *   hydra_jtag_tap      IEEE 1149.1 controller, IDCODE, BYPASS and a 40-bit
 *                       user register (instruction 0x8). Proved: five TCKs
 *                       with TMS high reach Test-Logic-Reset from any state.
 *   hydra_jtag_bridge   the toggle handshake that carries one {rw, addr,
 *                       data} request from TCK into the system clock.
 *
 * This file adds only the three registers the probe sees on that bridge:
 *
 *   addr 0x00  read   ID, 0x484A4231 ("HJB1")
 *   addr 0x01  write  data[7:0] is one command byte for the bridge
 *   addr 0x02  read   pop one reply byte:
 *                     {valid, 7'b0, count[7:0], 8'b0, byte}
 *                     valid = 0 means the queue was empty (byte is 0);
 *                     count is the number left AFTER this pop
 *   anything else     reads 0, writes are ignored
 *
 * A reply (up to 34 bytes) is produced at the system clock, far faster than
 * a probe can read it, so it waits in a 64-byte queue. A full queue holds
 * the bridge's reply state machine back; it never drops a byte.
 *
 * TDO is driven only while shifting (tdo_oe), as the TAP produces it; a
 * board top that cannot tri-state may drive it continuously, which is safe
 * on a point-to-point probe cable.
 */
`default_nettype none

module hydra_fpga_jtag_host #(
  parameter logic [31:0] IDCODE = 32'h1130_001D
) (
  // ---- probe pins (TCK domain) ---------------------------------------------
  input  wire        tck,
  input  wire        tms,
  input  wire        tdi,
  output wire        tdo,
  output wire        tdo_oe,

  // ---- system domain --------------------------------------------------------
  input  wire        clk,
  input  wire        rst_n,
  output logic       jb_rx_v,
  output logic [7:0] jb_rx_d,
  input  wire        jb_tx_v,
  input  wire  [7:0] jb_tx_d,
  output wire        jb_tx_full
);
  localparam int unsigned AW = 7, DW = 32, DEPTH = 64;
  localparam logic [31:0] HJB_ID = 32'h484A_4231;     // "HJB1"

  // ---- TCK side: the verified controller and crossing -----------------------
  logic [AW+DW:0] user_dr, user_capture;
  logic           user_update, in_reset;
  logic [3:0]     ir;

  hydra_jtag_tap #(.IRW(4), .IDCODE(IDCODE), .DRW(AW + DW + 1)) u_tap (
    .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo), .tdo_oe(tdo_oe),
    .user_dr(user_dr), .user_update(user_update), .user_capture(user_capture),
    .ir(ir), .in_reset(in_reset));

  logic          reg_we, reg_re;
  logic [AW-1:0] reg_addr;
  logic [DW-1:0] reg_wdata;
  logic [DW-1:0] reg_rdata;

  hydra_jtag_bridge #(.AW(AW), .DW(DW)) u_xing (
    .tck(tck), .trst_n(!in_reset),
    .user_dr(user_dr), .user_update(user_update), .user_capture(user_capture),
    .clk(clk), .rst_n(rst_n),
    .reg_we(reg_we), .reg_re(reg_re), .reg_addr(reg_addr),
    .reg_wdata(reg_wdata), .reg_rdata(reg_rdata));

  // ---- system side: command bytes out, reply bytes queued -------------------
  logic [7:0]               q [DEPTH];
  logic [$clog2(DEPTH)-1:0] wp, rp;
  logic [$clog2(DEPTH):0]   cnt;

  assign jb_tx_full = (cnt == ($clog2(DEPTH)+1)'(DEPTH));

  wire pop  = reg_re && (reg_addr == AW'('h02)) && (cnt != 0);
  wire push = jb_tx_v && !jb_tx_full;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      jb_rx_v <= 1'b0; jb_rx_d <= '0;
      wp <= '0; rp <= '0; cnt <= '0;
      reg_rdata <= '0;
    end else begin
      // a write to 0x01 is one command byte, presented for exactly one clock
      jb_rx_v <= reg_we && (reg_addr == AW'('h01));
      if (reg_we && (reg_addr == AW'('h01))) jb_rx_d <= reg_wdata[7:0];

      if (push) begin q[wp] <= jb_tx_d; wp <= wp + 1'b1; end
      if (pop)  rp <= rp + 1'b1;
      cnt <= cnt + (push ? 1'b1 : 1'b0) - (pop ? 1'b1 : 1'b0);

      // hydra_jtag_bridge samples reg_rdata one clock after reg_re
      if (reg_re) begin
        unique case (reg_addr)
          AW'('h00): reg_rdata <= HJB_ID;
          AW'('h02): reg_rdata <= (cnt != 0)
                       ? {1'b1, 7'd0, 8'(cnt - 1'b1), 8'd0, q[rp]}
                       : 32'd0;
          default:   reg_rdata <= 32'd0;
        endcase
      end
    end
  end

  wire _unused = &{ir, reg_wdata[DW-1:8], 1'b0};
endmodule

`default_nettype wire
