/*
 * hydra_openframe_top.sv
 *
 * HYDRA-130 sky130 target: the OpenFrame padframe wrapper
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT THIS IS, AND WHAT IT IS NOT
 * ===========================================================================
 * This is the full-chip target: a ChipFoundry OpenFrame user project, 44 pads,
 * about 15 mm2 of user area, hardened as macros and assembled here.
 *
 * Today it contains ONE macro -- the TinyTapeout tile (the MOM dispatcher).
 * That is deliberate. It makes the chip target real and testable now: the pad
 * plan, the pad multiplexer, the bring-up sequence and the chip-level
 * testbench all exist and run, and each SoC block drops in beside the tile as
 * its sources arrive. A wrapper with nothing in it proves nothing.
 *
 * The port list is copied from ChipFoundry's openframe_project_wrapper -- and
 * "copied" is the risk, so tools/check_openframe_ports.py diffs it against the
 * upstream file and fails if they have diverged.
 *
 * ===========================================================================
 * PAD PLAN (44 pads)
 * ===========================================================================
 *    0      clk            input, free-running
 *    1      rst_n          input, asynchronous, active low
 *    2      connect        strap: 1 connects the tile to the pads, 0 keeps
 *                          every pad inert. Sampled after reset, then locked.
 *                          The tile is held in reset until this has happened,
 *                          so it samples its own straps from real pins.
 *    3-10   ui_in[7:0]     tile inputs   (SPI: 3 = SCK, 4 = COPI, 5 = CSn)
 *   11-18   uo_out[7:0]    tile outputs  (SPI: 11 = CIPO)
 *   19-26   uio[7:0]       tile bidirectionals
 *   27-43   unused         input buffers disabled, outputs off
 *
 * ===========================================================================
 * WHY THE PAD MULTIPLEXER IS HERE FOR A DESIGN THAT FITS
 * ===========================================================================
 * The SoC needs 45 signals and OpenFrame has 44 pads, so pads must carry more
 * than one function eventually. Rather than bolt that on later, every
 * functional pad already goes through hydra_padmux (proved, 8/8 mutations
 * killed) with two alternatives: 0 is inert, 1 is the tile. Three consequences
 * that matter on silicon:
 *   - reset leaves every pad an input, so nothing is driven while the chip
 *     powers up and the bring-up board is being probed;
 *   - a chip that comes back with a wiring mistake can be held in the inert
 *     personality and probed, instead of fighting the board;
 *   - the selection locks, so firmware cannot re-route pins after boot.
 *
 * ===========================================================================
 * NOT VERIFIED HERE
 * ===========================================================================
 * The gpio_dm / vtrip / slow / analog control encodings below follow the
 * Caravel and OpenFrame convention (dm = 3'b110 for a digital output driver,
 * input buffer enabled by gpio_inp_dis = 0). They have NOT been checked
 * against silicon or against ChipFoundry's CF_gpio_config in this session.
 * Check them against the OpenFrame user guide before submitting: a wrong
 * drive-mode code turns a working design into a chip that cannot talk.
 * ===========================================================================
 */
`default_nettype none

`ifndef OPENFRAME_IO_PADS
`define OPENFRAME_IO_PADS 44
`endif

module openframe_project_wrapper (
  inout  vdda,  inout vdda1, inout vdda2,
  inout  vssa,  inout vssa1, inout vssa2,
  inout  vccd,  inout vccd1, inout vccd2,
  inout  vssd,  inout vssd1, inout vssd2,
  inout  vddio, inout vssio,

  input        porb_h,
  input        porb_l,
  input        por_l,
  input        resetb_h,
  input        resetb_l,
  input [31:0] mask_rev,

  input  [`OPENFRAME_IO_PADS-1:0] gpio_in,
  input  [`OPENFRAME_IO_PADS-1:0] gpio_in_h,
  output [`OPENFRAME_IO_PADS-1:0] gpio_out,
  output [`OPENFRAME_IO_PADS-1:0] gpio_oeb,
  output [`OPENFRAME_IO_PADS-1:0] gpio_inp_dis,
  output [`OPENFRAME_IO_PADS-1:0] gpio_ib_mode_sel,
  output [`OPENFRAME_IO_PADS-1:0] gpio_vtrip_sel,
  output [`OPENFRAME_IO_PADS-1:0] gpio_slow_sel,
  output [`OPENFRAME_IO_PADS-1:0] gpio_holdover,
  output [`OPENFRAME_IO_PADS-1:0] gpio_analog_en,
  output [`OPENFRAME_IO_PADS-1:0] gpio_analog_sel,
  output [`OPENFRAME_IO_PADS-1:0] gpio_analog_pol,
  output [`OPENFRAME_IO_PADS-1:0] gpio_dm2,
  output [`OPENFRAME_IO_PADS-1:0] gpio_dm1,
  output [`OPENFRAME_IO_PADS-1:0] gpio_dm0,

  inout  [`OPENFRAME_IO_PADS-1:0] analog_io,
  inout  [`OPENFRAME_IO_PADS-1:0] analog_noesd_io,

  input  [`OPENFRAME_IO_PADS-1:0] gpio_loopback_one,
  input  [`OPENFRAME_IO_PADS-1:0] gpio_loopback_zero
);

  localparam int NPADS    = `OPENFRAME_IO_PADS;
  localparam int P_CLK    = 0;
  localparam int P_RSTN   = 1;
  localparam int P_CONN   = 2;
  localparam int P_FIRST  = 3;          // first multiplexed pad
  localparam int NMUX     = 24;         // ui 8 + uo 8 + uio 8
  localparam int NALT     = 2;

  wire _unused = &{porb_h, por_l, resetb_h, mask_rev, gpio_in_h,
                   gpio_loopback_one, gpio_loopback_zero, 1'b0};

  // ---------------------------------------------------------------------------
  // Clock and reset. porb_l and resetb_l are both power-on/master resets in
  // the 1.8 V domain; either one holds the design in reset, as does the pad.
  // ---------------------------------------------------------------------------
  wire clk    = gpio_in[P_CLK];
  wire arst_n = gpio_in[P_RSTN] & porb_l & resetb_l;

  wire rst_n;
  hydra_rst_sync u_rst (
    .clk(clk), .arst_n(arst_n), .scan_mode(1'b0), .scan_rst_n(1'b1), .rst_n(rst_n));

  // ---------------------------------------------------------------------------
  // The tile
  // ---------------------------------------------------------------------------
  wire [7:0] ui_in, uo_out, uio_in, uio_out, uio_oe;
  wire       padmux_locked;
  logic [1:0] tile_rel;

  // BRING-UP ORDER, and why it is not the obvious one.
  // The tile samples its personality strap (ui_in[7:4]) while ITS reset is
  // low. Until the pad multiplexer is connected, ui_in reads the inert idle
  // values, not the pins -- so releasing both resets together boots the tile
  // in the wrong personality with the pins right there. The tile is therefore
  // held in reset until the pads are connected and locked, and only then let
  // go. Caught by tb_openframe, which read an ID of zero.
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) tile_rel <= 2'd0;
    else if (padmux_locked && tile_rel != 2'd3) tile_rel <= tile_rel + 2'd1;

  wire tile_rst_n = rst_n & (tile_rel == 2'd3);

  hydra_mom_pins u_tile (
    .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
    .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(tile_rst_n));

  // ---------------------------------------------------------------------------
  // Pad multiplexer: alternative 0 inert, alternative 1 the tile.
  // ---------------------------------------------------------------------------
  wire [NMUX*NALT-1:0] alt_out, alt_oe, alt_idle, alt_in;
  wire [NMUX-1:0]      pad_out, pad_oe, pad_in;

  genvar i;
  generate
    for (i = 0; i < NMUX; i++) begin : g_alt
      // alternative 0: inert. Never drives; a function reading it sees idle.
      assign alt_out [i*NALT + 0] = 1'b0;
      assign alt_oe  [i*NALT + 0] = 1'b0;
      assign alt_idle[i*NALT + 0] = 1'b0;

      if (i < 8) begin : g_ui            // inputs
        assign alt_out [i*NALT + 1] = 1'b0;
        assign alt_oe  [i*NALT + 1] = 1'b0;
        // An unconnected SPI chip-select must read high, not float low, or the
        // tile sees a frame the moment the personality is applied.
        assign alt_idle[i*NALT + 1] = (i == 5) ? 1'b1 : 1'b0;
        assign ui_in[i]             = alt_in[i*NALT + 1];
      end else if (i < 16) begin : g_uo  // outputs
        assign alt_out [i*NALT + 1] = uo_out[i - 8];
        assign alt_oe  [i*NALT + 1] = 1'b1;
        assign alt_idle[i*NALT + 1] = 1'b0;
      end else begin : g_uio             // bidirectionals
        assign alt_out [i*NALT + 1] = uio_out[i - 16];
        assign alt_oe  [i*NALT + 1] = uio_oe [i - 16];
        assign alt_idle[i*NALT + 1] = 1'b0;
        assign uio_in[i - 16]       = alt_in[i*NALT + 1];
      end
    end
  endgenerate

  // Bring-up: a few clocks after reset, connect the tile if the strap says so,
  // then lock. Held inert otherwise, which is the state a bad board wants.
  logic [3:0] boot_cnt;
  logic       cfg_we, cfg_lock;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      boot_cnt <= 4'd0; cfg_we <= 1'b0; cfg_lock <= 1'b0;
    end else begin
      cfg_we   <= 1'b0;
      cfg_lock <= 1'b0;
      if (boot_cnt != 4'd8) begin
        boot_cnt <= boot_cnt + 4'd1;
      end else if (!cfg_lock) begin
        boot_cnt <= 4'd9;
        cfg_we   <= gpio_in[P_CONN];
        cfg_lock <= gpio_in[P_CONN];
      end
    end
  end

  hydra_padmux #(.NPAD(NMUX), .NALT(NALT), .SELW(1), .RESET_SEL({NMUX{1'b0}})) u_padmux (
    .clk(clk), .rst_n(rst_n),
    .cfg_we(cfg_we), .cfg_sel({NMUX{1'b1}}), .cfg_lock(cfg_lock),
    .sel_q(), .locked_q(padmux_locked),
    .alt_out(alt_out), .alt_oe(alt_oe), .alt_idle(alt_idle), .alt_in(alt_in),
    .pad_out(pad_out), .pad_oe(pad_oe), .pad_in(pad_in));

  assign pad_in = gpio_in[P_FIRST +: NMUX];

  // ---------------------------------------------------------------------------
  // Pad control. oeb is active low.
  // ---------------------------------------------------------------------------
  wire [NPADS-1:0] out_w, oeb_w, inp_dis_w;
  assign out_w     = {{(NPADS - P_FIRST - NMUX){1'b0}}, pad_out, {P_FIRST{1'b0}}};
  assign oeb_w     = {{(NPADS - P_FIRST - NMUX){1'b1}}, ~pad_oe, {P_FIRST{1'b1}}};
  // Input buffers on for the clock, reset, strap and every multiplexed pad;
  // off for the unused ones so they cannot float and burn current.
  assign inp_dis_w = {{(NPADS - P_FIRST - NMUX){1'b1}}, {NMUX{1'b0}}, {P_FIRST{1'b0}}};

  assign gpio_out     = out_w;
  assign gpio_oeb     = oeb_w;
  assign gpio_inp_dis = inp_dis_w;

  // Digital, no analog, standard trip point, fast slew, no holdover.
  assign gpio_dm2         = ~oeb_w;      // dm = 110 driving, 001 receiving
  assign gpio_dm1         = ~oeb_w;
  assign gpio_dm0         =  oeb_w;
  assign gpio_ib_mode_sel = {NPADS{1'b0}};
  assign gpio_vtrip_sel   = {NPADS{1'b0}};
  assign gpio_slow_sel    = {NPADS{1'b0}};
  assign gpio_holdover    = {NPADS{1'b0}};
  assign gpio_analog_en   = {NPADS{1'b0}};
  assign gpio_analog_sel  = {NPADS{1'b0}};
  assign gpio_analog_pol  = {NPADS{1'b0}};

endmodule

`default_nettype wire
