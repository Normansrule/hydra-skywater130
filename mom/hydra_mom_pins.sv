/*
 * hydra_mom_pins.sv
 *
 * HYDRA-130 - the dispatcher (MOM) behind eight pins in, eight out, eight
 * bidirectional: the full version, as the chip and the FPGA images use it
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHERE THIS CAME FROM
 * ===========================================================================
 * Until 2026-10-09 this was the Tiny Tapeout tile's top level,
 * tt_um_hydra_mom, and the chip compiled the tile's sources. The tile is now
 * a research tile (tinytapeout-hydra, v3): register map only, four tags, no
 * descriptor readback, on 3x4 tiles. The chip keeps everything here -- both
 * host personalities, eight tags, LASTWD -- because on the chip the
 * descriptor travels on to a real engine and a v1 host may be attached.
 *
 * The dispatcher's modules in mom/rtl are byte-identical to the tile's except
 * hydra_tt_regs.sv; `make tile-shared` enforces that, so the verification of
 * one covers the other.
 *
 * ===========================================================================
 * THE PIN PROBLEM
 * ===========================================================================
 * A work descriptor is 128 bits. TinyTapeout gives 8 inputs, 8 outputs, and 8
 * bidirectionals. So the descriptor is shifted in serially, one bit per clock,
 * and the result is read back in parallel.
 *
 * Shifting 128 bits at, say, 10 MHz takes 12.8 us. The dispatch decision that
 * follows takes 3 cycles, 300 ns. The interface is 40x slower than the thing
 * it is testing, which is fine: this measures whether dispatch is CORRECT and
 * what Fmax it closes at, not how fast a descriptor can be loaded.
 *
 * ===========================================================================
 * PIN MAP
 * ===========================================================================
 * ui_in[0]    sdi        serial descriptor data, MSB first
 * ui_in[1]    shift      shift sdi into the descriptor register on this edge
 * ui_in[2]    go         present the descriptor to the MOM and latch the result
 * ui_in[3]    comp       pulse a completion for the tag on ui_in[7:4]
 * ui_in[7:4]  comp_tag   tag to complete
 *
 * uo_out[2:0] engine     selected engine index
 * uo_out[3]   dispatched a dispatch occurred for the last `go`
 * uo_out[4]   unsupported no engine could execute the last descriptor
 * uo_out[5]   stale      a completion arrived for a tag not in flight
 * uo_out[6]   any_busy   at least one tag outstanding
 * uo_out[7]   ready      the MOM can accept a descriptor
 *
 * uio_out[3:0] tag       tag allocated by the last dispatch
 * uio_out[7:4] margin    top nibble of the runner-up margin, saturated
 * uio_oe                 all ones: every bidirectional is an output here
 *
 * ===========================================================================
 * v2 (SESSION 179): TWO PERSONALITIES, SELECTED BY STRAP AT RESET
 * ===========================================================================
 * LEGACY (default): the v1 pin map above, unchanged. Every v1 test runs
 *   unmodified against v2, and tb_v1_v2_diff compares v2 against the v1 RTL
 *   pin-for-pin on random stimulus.
 * REGISTER: hold ui_in[7:4] = 4'hA while rst_n is low. Then
 *   ui_in[0] SCK   ui_in[1] COPI   ui_in[2] CSn     (SPI mode 0, <= clk/8)
 *   uo_out[0] CIPO  uo_out[1] IRQ  uo_out[4:2] engine  uo_out[5] dispatched
 *   uo_out[6] any_busy  uo_out[7] ready     uio_out = {margin, tag} as v1
 *   and the whole mom_top interface is reachable: see hydra_tt_regs.sv.
 * The strap is sampled on every clock while reset is held, so it needs no
 * reset value of its own and is stable from the first cycle after reset.
 * A host that holds ui_in at 0 through reset (every v1 test, and the
 * demoboard default) gets LEGACY. 4'hA was chosen because a v1 host never
 * drives ui_in[7:4] during reset.
 *
 * v2 ALSO FIXES the v1 margin nibble. v1 saturated when
 * obs_margin[31:12] != 0 and otherwise output obs_margin[15:12] -- a subset
 * of the bits just tested, so it could only ever read 0 or F. Both v1 runs
 * in session 144 logged margin 0. v2 saturates on [31:16], as the comment
 * ("anything above 15 * 4096 reads as clear") intended.
 * ===========================================================================
 *
 * A LESSON CARRIED OVER FROM ASICIRIFIC
 * ===========================================================================
 * The `tiles` value in info.yaml and the DIE_AREA in the hardened config must
 * agree. On the ASICirific submission they did not, because the project's
 * src/config.json was missing `FP_SIZING: "absolute"`, so LibreLane ignored
 * DIE_AREA and auto-sized the die. DRC, LVS, and timing all passed against the
 * WRONG die, and the only symptom was a boundary XOR failure that looked like
 * a tool bug. It cost three weeks.
 *
 * Use the stock TinyTapeout src/config.json for this project, unmodified. If
 * area needs tuning, change `tiles` in info.yaml and let the flow regenerate
 * the config. Do not hand-edit the floorplan settings.
 * ===========================================================================
 */

`default_nettype none

module hydra_mom_pins
  import mom_pkg::*;
(
  input  wire [7:0] ui_in,
  output wire [7:0] uo_out,
  input  wire [7:0] uio_in,
  output wire [7:0] uio_out,
  output wire [7:0] uio_oe,
  input  wire       ena,
  input  wire       clk,
  input  wire       rst_n
);

  // ===========================================================================
  // RESET: asserted asynchronously, RELEASED synchronously
  // ===========================================================================
  // The rst_n pin used to drive every asynchronously-reset flip-flop directly
  // -- about 2,500 of them. Two problems with that, one physical and one
  // logical:
  //
  //   TIMING   every recovery check started at an INPUT PIN, carrying the
  //            input delay the constraints assign to pins (20% of the
  //            period), then crossed a buffer tree to thousands of loads.
  //            The slow corner missed timing even after the clock period was
  //            lengthened from 55 to 66 ns, which is the signature of a path
  //            that does not scale with the clock.
  //   LOGIC    release was asynchronous to the clock, so different
  //            flip-flops could leave reset on different cycles.
  //
  // hydra_rst_sync (formally verified in the parent repository) asserts the
  // moment rst_n falls and releases only after STAGES clean clock edges.
  // Recovery checks now start at a REGISTER, inside the clock domain.
  //
  // The mode strap is the one deliberate exception: it is sampled from the
  // raw pin while reset is held, which is when the strap is valid.
  wire rst_n_sync;
  hydra_rst_sync #(.STAGES(2)) u_rst_sync (
    .clk(clk), .arst_n(rst_n), .scan_mode(1'b0), .scan_rst_n(1'b1),
    .rst_n(rst_n_sync));

  localparam int unsigned NTAG = 8;

  wire _unused = &{ena, uio_in, 1'b0};

  // ---------------------------------------------------------------------------
  // Personality strap.
  // ---------------------------------------------------------------------------
  logic reg_mode;
  always_ff @(posedge clk)
    if (!rst_n) reg_mode <= (ui_in[7:4] == 4'hA);

  // =========================================================================
  // LEGACY front end -- identical to v1
  // =========================================================================
  wire sdi      = ui_in[0];
  wire shift    = ui_in[1];
  wire go       = ui_in[2];
  wire comp     = ui_in[3];
  wire [3:0] comp_tag_in = ui_in[7:4];

  logic [WD_W-1:0] sr;
  always_ff @(posedge clk or negedge rst_n_sync)
    if (!rst_n_sync)                  sr <= '0;
    else if (!reg_mode && shift) sr <= {sr[WD_W-2:0], sdi};

  logic go_q, comp_q;
  always_ff @(posedge clk or negedge rst_n_sync)
    if (!rst_n_sync) begin go_q <= 1'b0; comp_q <= 1'b0; end
    else        begin go_q <= go;   comp_q <= comp; end

  wire go_pulse   = ~reg_mode & go   & ~go_q;
  wire comp_pulse = ~reg_mode & comp & ~comp_q;

  // =========================================================================
  // REGISTER front end
  // =========================================================================
  wire       spi_cipo, cs_start, cs_end, cs_active, rx_valid, tx_load;
  wire [7:0] rx_byte, tx_byte;
  wire [4:0] rx_index;

  // Pins are gated off in legacy mode so the SPI block sees an idle bus and
  // cannot mistake legacy traffic for frames.
  hydra_tt_spi u_spi (
    .clk(clk), .rst_n(rst_n_sync),
    .sck_i(reg_mode & ui_in[0]), .copi_i(reg_mode & ui_in[1]),
    .csn_i(~reg_mode | ui_in[2]), .cipo_o(spi_cipo),
    .cs_start(cs_start), .cs_end(cs_end), .cs_active(cs_active),
    .rx_valid(rx_valid), .rx_byte(rx_byte), .rx_index(rx_index),
    .tx_load(tx_load), .tx_byte(tx_byte)
  );

  wire               r_wd_valid, r_disp_accept, r_comp_valid, r_csr_wr, r_csr_priv;
  wire               r_cal_freeze, r_cal_reset, r_irq, r_disp_sticky;
  wire [WD_W-1:0]    r_wd;
  wire [3:0]         r_comp_tag, r_fence_tag, r_bw, r_eps, r_esh, r_last_tag, r_margin_nib;
  wire [2:0]         r_csr_engine, r_last_engine;
  wire [EPARAM_W-1:0] r_csr_data;

  // =========================================================================
  // MOM -- one instance, inputs selected by personality
  // =========================================================================
  wire               disp_valid;
  wire  [2:0]        disp_engine;
  wire  [3:0]        disp_tag;
  work_desc_t        disp_wd;
  wire               err_unsupported;
  wire  [7:0]        err_tag;
  wire               err_stale_comp;
  wire  [COST_W-1:0] obs_margin;
  wire  [NTAG-1:0]   obs_tag_busy;
  wire  [15:0]       obs_cal_updates;
  wire               wd_ready;
  wire               fence_busy;

  hydra_tt_regs #(.NTAG(NTAG)) u_regs (
    .clk(clk), .rst_n(rst_n_sync),
    .cs_start(cs_start), .cs_end(cs_end), .rx_valid(rx_valid),
    .rx_byte(rx_byte), .rx_index(rx_index), .tx_load(tx_load), .tx_byte(tx_byte),
    .wd_valid(r_wd_valid), .wd_ready(wd_ready), .wd(r_wd),
    .disp_valid(disp_valid), .disp_accept(r_disp_accept),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(r_comp_valid), .comp_tag(r_comp_tag),
    .fence_tag(r_fence_tag), .fence_busy(fence_busy),
    .csr_wr(r_csr_wr), .csr_priv(r_csr_priv), .csr_engine(r_csr_engine),
    .csr_data(r_csr_data), .csr_bw_dma_log2(r_bw), .csr_eps_mem(r_eps),
    .csr_e_shift(r_esh), .csr_cal_freeze(r_cal_freeze), .csr_cal_reset(r_cal_reset),
    .err_unsupported(err_unsupported), .err_tag(err_tag),
    .err_stale_comp(err_stale_comp), .obs_margin(obs_margin),
    .obs_cal_updates(obs_cal_updates), .obs_tag_busy(obs_tag_busy),
    .irq(r_irq), .last_engine(r_last_engine), .disp_sticky(r_disp_sticky),
    .last_tag(r_last_tag), .margin_nib(r_margin_nib)
  );

  wire disp_accept = reg_mode ? r_disp_accept : 1'b1;

  mom_top #(.NTAG(NTAG), .QMAX(4)) u_mom (
    .clk(clk), .rst_n(rst_n_sync),
    .wd_valid(reg_mode ? r_wd_valid : go_pulse), .wd_ready(wd_ready),
    .wd(work_desc_t'(reg_mode ? r_wd : sr)),
    .disp_valid(disp_valid), .disp_accept(disp_accept),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(reg_mode ? r_comp_valid : comp_pulse),
    .comp_tag(reg_mode ? r_comp_tag : comp_tag_in),
    .fence_tag(reg_mode ? r_fence_tag : 4'd0), .fence_busy(fence_busy),
    .csr_wr(reg_mode & r_csr_wr), .csr_priv(reg_mode & r_csr_priv),
    .csr_engine(reg_mode ? r_csr_engine : 3'd0),
    .csr_data(reg_mode ? r_csr_data : {EPARAM_W{1'b0}}),
    .csr_bw_dma_log2(reg_mode ? r_bw  : 4'd4),
    .csr_eps_mem    (reg_mode ? r_eps : 4'd12),
    .csr_e_shift    (reg_mode ? r_esh : 4'd8),
    .csr_cal_freeze(reg_mode & r_cal_freeze), .csr_cal_reset(reg_mode & r_cal_reset),
    .err_unsupported(err_unsupported), .err_tag(err_tag),
    .err_stale_comp(err_stale_comp),
    .obs_margin(obs_margin), .obs_cal_updates(obs_cal_updates),
    .obs_tag_busy(obs_tag_busy)
  );

  // =========================================================================
  // LEGACY result latch -- identical to v1 except the margin fix
  // =========================================================================
  logic [2:0]  l_engine;
  logic [3:0]  l_tag;
  logic        l_disp, l_unsupp, l_stale;
  logic [3:0]  l_margin;

  wire [3:0] margin_nib = (obs_margin[COST_W-1:16] != '0) ? 4'hF
                                                          : obs_margin[15:12];

  always_ff @(posedge clk or negedge rst_n_sync) begin
    if (!rst_n_sync) begin
      l_engine <= 3'd0; l_tag <= 4'd0;
      l_disp   <= 1'b0; l_unsupp <= 1'b0; l_margin <= 4'd0;
    end else begin
      if (go_pulse) begin
        l_disp   <= 1'b0;
        l_unsupp <= 1'b0;
      end
      if (disp_valid) begin
        l_engine <= disp_engine;
        l_tag    <= disp_tag;
        l_margin <= margin_nib;
        l_disp   <= 1'b1;
      end
      if (err_unsupported) l_unsupp <= 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n_sync)
    if (!rst_n_sync)              l_stale <= 1'b0;
    else if (err_stale_comp) l_stale <= 1'b1;

  // =========================================================================
  // Pins
  // =========================================================================
  wire ready    = wd_ready;
  wire any_busy = |obs_tag_busy;

  assign uo_out = reg_mode
    ? { ready, any_busy, r_disp_sticky, r_last_engine, r_irq, spi_cipo }
    : { ready, any_busy, l_stale, l_unsupp, l_disp, l_engine };

  assign uio_out = reg_mode ? { r_margin_nib, r_last_tag } : { l_margin, l_tag };
  assign uio_oe  = 8'hFF;      // every bidirectional is an output, both modes

  wire _unused_spi = &{cs_active, 1'b0};

endmodule

`default_nettype wire
