/*
 * tt_um_hydra_mom.sv
 *
 * HYDRA-130 - TinyTapeout spinout of the Mathematical Operation MUX (TT-A)
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY TAPE OUT A SCHEDULER ON ITS OWN
 * ===========================================================================
 * The MOM is the novel block in HYDRA-130 and the one a paper would rest on.
 * Everything about it is verified in simulation: 10,000-vector cross-check
 * against an independent model, a closed-loop calibration test, and formal
 * proofs on five modules.
 *
 * None of that is silicon. A TinyTapeout tile costs a fraction of a shuttle
 * slot and answers questions simulation cannot:
 *
 *   - Does the three-cycle dispatch path close timing at a real Fmax?
 *   - What is the actual gate count against a real standard cell library?
 *   - Does the calibration loop converge on hardware, with real latencies
 *     rather than a testbench's fixed delays?
 *
 * A block that survives TinyTapeout silicon has earned its place on the big
 * die. One that does not has cost a few hundred euros instead of a shuttle.
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

module tt_um_hydra_mom_v1
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

  // ---------------------------------------------------------------------------
  // Unused inputs are tied into a dummy so the linter does not complain and,
  // more importantly, so nothing floats. `ena` is driven by the TT mux and is
  // deliberately ignored: the design is always enabled when selected.
  // ---------------------------------------------------------------------------
  wire _unused = &{ena, uio_in, 1'b0};

  wire sdi      = ui_in[0];
  wire shift    = ui_in[1];
  wire go       = ui_in[2];
  wire comp     = ui_in[3];
  wire [3:0] comp_tag_in = ui_in[7:4];

  // ---------------------------------------------------------------------------
  // Descriptor shift register, MSB first.
  //
  // No handshake and no bit counter: the host shifts exactly WD_W times and
  // then pulses `go`. Counting on-chip would add a comparator and a counter to
  // catch a mistake the host controls anyway, and the host can simply shift
  // again if it loses count.
  // ---------------------------------------------------------------------------
  logic [WD_W-1:0] sr;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)     sr <= '0;
    else if (shift) sr <= {sr[WD_W-2:0], sdi};

  // ---------------------------------------------------------------------------
  // Edge detect on `go`.
  //
  // The host drives these pins from software at an unknown rate, so `go` may be
  // held high for many clocks. Without edge detection that would present the
  // same descriptor over and over, allocating a tag every cycle until all 16
  // are consumed. That exact bug appeared in the simulation testbench, where
  // holding wd_valid one cycle too long leaked a tag per vector; the RTL was
  // right and the driver was not. Pins are a driver.
  // ---------------------------------------------------------------------------
  logic go_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) go_q <= 1'b0;
    else        go_q <= go;

  wire go_pulse = go & ~go_q;

  logic comp_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) comp_q <= 1'b0;
    else        comp_q <= comp;

  wire comp_pulse = comp & ~comp_q;

  // ---------------------------------------------------------------------------
  // MOM instance. NTAG is cut from 16 to 8 for this tile: sixteen tags exist to
  // cover dispatch bursts from a CPU, and the host here shifts 128 bits between
  // descriptors, so there is never more than a handful in flight. Eight saves
  // roughly 450 flops that would otherwise buy nothing.
  // ---------------------------------------------------------------------------
  wire               disp_valid;
  wire  [2:0]        disp_engine;
  wire  [3:0]        disp_tag;
  work_desc_t        disp_wd;
  wire               err_unsupported;
  wire  [7:0]        err_tag;
  wire               err_stale_comp;
  wire  [COST_W-1:0] obs_margin;
  wire  [7:0]        obs_tag_busy;
  wire  [15:0]       obs_cal_updates;
  wire               wd_ready;

  mom_top #(.NTAG(8), .QMAX(4)) u_mom (
    .clk(clk), .rst_n(rst_n),
    .wd_valid(go_pulse), .wd_ready(wd_ready), .wd(work_desc_t'(sr)),
    .disp_valid(disp_valid), .disp_accept(1'b1),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(comp_pulse), .comp_tag(comp_tag_in),
    .fence_tag(4'd0), .fence_busy(),

    // Parameter ROM is left at its reset defaults. Exposing the CSR write port
    // would need a second serial channel for 43 bits per row, and the defaults
    // are what the whole verification suite was run against. Retuning is a
    // v2 feature.
    .csr_wr(1'b0), .csr_priv(1'b0), .csr_engine(3'd0),
    .csr_data({EPARAM_W{1'b0}}),
    .csr_bw_dma_log2(4'd4), .csr_eps_mem(4'd12), .csr_e_shift(4'd8),

    // Calibration ENABLED. This is the point of the tile: watching the loop
    // converge against real completion latencies, not testbench delays.
    .csr_cal_freeze(1'b0), .csr_cal_reset(1'b0),

    .err_unsupported(err_unsupported), .err_tag(err_tag),
    .err_stale_comp(err_stale_comp),
    .obs_margin(obs_margin), .obs_cal_updates(obs_cal_updates),
    .obs_tag_busy(obs_tag_busy)
  );

  // ---------------------------------------------------------------------------
  // Result latch.
  //
  // Held until the next `go` rather than presented combinationally, so the host
  // can read the pins at its leisure. A combinational output would require the
  // host to sample within one clock of the dispatch, which is not possible when
  // the host is software toggling GPIO.
  // ---------------------------------------------------------------------------
  logic [2:0]  r_engine;
  logic [3:0]  r_tag;
  logic        r_disp, r_unsupp;
  logic [3:0]  r_margin;

  // Margin saturated into a nibble. The absolute value is not interesting; the
  // question is whether the decision was close or clear, and four bits answers
  // that. Anything above 15 * 4096 reads as "clear".
  wire [3:0] margin_nib = (obs_margin[COST_W-1:12] != '0) ? 4'hF
                                                          : obs_margin[15:12];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_engine <= 3'd0; r_tag <= 4'd0;
      r_disp   <= 1'b0; r_unsupp <= 1'b0; r_margin <= 4'd0;
    end else begin
      if (go_pulse) begin
        // Clear on a new request so a stale result cannot be mistaken for a
        // fresh one if the descriptor turns out to be unsupported.
        r_disp   <= 1'b0;
        r_unsupp <= 1'b0;
      end
      if (disp_valid) begin
        r_engine <= disp_engine;
        r_tag    <= disp_tag;
        r_margin <= margin_nib;
        r_disp   <= 1'b1;
      end
      if (err_unsupported) r_unsupp <= 1'b1;
    end
  end

  // Sticky, because a one-cycle pulse cannot be caught by software polling.
  // Cleared only by reset, which is the honest behaviour for an error flag.
  logic r_stale;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)              r_stale <= 1'b0;
    else if (err_stale_comp) r_stale <= 1'b1;

  assign uo_out = { wd_ready,
                    |obs_tag_busy,
                    r_stale,
                    r_unsupp,
                    r_disp,
                    r_engine };

  assign uio_out = { r_margin, r_tag };
  assign uio_oe  = 8'hFF;      // every bidirectional is an output

endmodule

`default_nettype wire
