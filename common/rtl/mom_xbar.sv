/*
 * mom_xbar.sv
 *
 * HYDRA-130: the crossbar between the Mathematical Operation MUX and the
 *            engines it chooses
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY THIS BLOCK EXISTS
 * ===========================================================================
 * The MOM decides. Nothing in the SoC carries the decision out. `mom_top`
 * presents disp_valid / disp_engine / disp_tag / disp_wd and waits for
 * disp_accept, and today the only thing that ever accepted was a testbench or
 * a host register write. Until something routes work to the chosen engine and
 * routes the completion back, the dispatcher is a very well verified opinion.
 *
 * This is also what closes the calibration loop IN HARDWARE. Today the loop
 * only closes when a host writes COMP after watching the clock; with the
 * crossbar the engine's own completion feeds mom_calibrate, which is the
 * claim the project actually wants to make on silicon.
 *
 * ===========================================================================
 * CONTRACT
 * ===========================================================================
 * Dispatch
 *   - A descriptor is forwarded to engine e only while that engine is idle.
 *     disp_accept is asserted in the same cycle the descriptor is forwarded,
 *     so the MOM's handshake is unchanged.
 *   - While the chosen engine is busy, disp_accept stays low and the MOM
 *     holds the descriptor. The dispatcher already tolerates this: it is the
 *     same back-pressure the register personality exercises with HOLD.
 *   - An out-of-range engine index can never be forwarded. It is ACCEPTED
 *     (so the machine cannot deadlock on a corrupt decision) and reported on
 *     err_bad_engine. Dropping it silently would look like a hung engine.
 *
 * Completion
 *   - Each engine reports done with the tag it was given. The crossbar checks
 *     that tag against what it handed that engine:
 *       wrong tag        -> err_done_unknown, completion NOT forwarded
 *       engine not busy  -> err_done_unknown, completion NOT forwarded
 *     A completion the scoreboard never issued would retire a live tag and
 *     corrupt the calibration sample. It must not reach the MOM.
 *   - A finished engine stays BUSY until its completion has been handed to
 *     the MOM. There is no completion queue to size, overflow or prove empty:
 *     the engine itself is the buffer, and it cannot be given new work while
 *     it holds an unreported result. "No completion is lost" then follows
 *     from a counter that is proved, not from a depth argument.
 *   - Round-robin across engines, so a fast engine completing every cycle
 *     cannot starve a slow one's completion.
 *
 * ===========================================================================
 * VERIFICATION
 * ===========================================================================
 *   common/tb/xbar_model.py     independent model, written from this contract
 *   common/tb/tb_mom_xbar.sv    20k random vectors, exact compare every cycle
 *   common/formal/mom_xbar.sby  proofs, including "no completion is lost"
 *   tt/tb/tb_mom_system.sv      the real mom_top driving real engine models:
 *                               the calibration loop closing with no host
 * ===========================================================================
 */
`default_nettype none

module mom_xbar #(
  parameter int NENG = 5,
  parameter int NTAG = 8,
  parameter int WD_W = 128,
  parameter int TAGW = 4,
  parameter int ENGW = 3
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // ---- from the dispatcher ------------------------------------------------
  input  logic                  disp_valid,
  output logic                  disp_accept,
  input  logic [ENGW-1:0]       disp_engine,
  input  logic [TAGW-1:0]       disp_tag,
  input  logic [WD_W-1:0]       disp_wd,

  // ---- back to the dispatcher --------------------------------------------
  output logic                  comp_valid,
  output logic [TAGW-1:0]       comp_tag,

  // ---- engine ports -------------------------------------------------------
  output logic [NENG-1:0]       eng_valid,
  input  logic [NENG-1:0]       eng_ready,      // engine can take work now
  output logic [WD_W-1:0]       eng_wd,         // shared: valid is one-hot
  output logic [NENG*TAGW-1:0]  eng_tag,
  input  logic [NENG-1:0]       eng_done,
  input  logic [NENG*TAGW-1:0]  eng_done_tag,

  // ---- status and errors --------------------------------------------------
  output logic [NENG-1:0]       eng_busy,
  output logic                  err_bad_engine,
  output logic                  err_done_unknown
);

  // ---------------------------------------------------------------------------
  // Per-engine state: busy, the tag it holds, and whether it has finished but
  // not yet been reported to the dispatcher.
  // ---------------------------------------------------------------------------
  logic [NENG-1:0] busy_q, pend_q;
  logic [TAGW-1:0] tag_q [NENG];
  logic [ENGW-1:0] rr_ptr;

  assign eng_busy = busy_q;

  // ---- dispatch -------------------------------------------------------------
  wire in_range = (32'(disp_engine) < ENGW'(NENG));
  wire target_free = in_range && !busy_q[disp_engine] && eng_ready[disp_engine];
  // Gated by rst_n, combinationally: a block in reset must not accept work or
  // start an engine, and rst_n here is the async-asserted output of
  // hydra_rst_sync, so this takes effect the instant reset asserts rather
  // than a clock later. (Caught by tb_mom_xbar: the model, written from the
  // contract, expected no accept during reset and the RTL was accepting.)
  wire fwd = rst_n && disp_valid && target_free;
  wire bad = rst_n && disp_valid && !in_range;

  always_comb begin
    eng_valid = '0;
    if (fwd) eng_valid[disp_engine] = 1'b1;
  end
  assign eng_wd      = disp_wd;
  assign disp_accept = fwd || bad;

  // The tag an engine sees must be the tag it is being GIVEN this cycle, not
  // the one it held before. tag_q only updates at the end of the cycle, so
  // the starting engine is overridden combinationally. Caught by
  // tb_mom_system: every engine reported a completion the crossbar had to
  // reject as unknown, because the engine had latched the previous tag.
  always_comb begin
    for (int e = 0; e < NENG; e++) begin
      eng_tag[e*TAGW +: TAGW] = tag_q[e];
      if (fwd && (ENGW'(e) == disp_engine)) eng_tag[e*TAGW +: TAGW] = disp_tag;
    end
  end

  // ---- completion checking --------------------------------------------------
  logic [NENG-1:0] done_ok;
  always_comb
    for (int e = 0; e < NENG; e++)
      done_ok[e] = eng_done[e] && busy_q[e] && !pend_q[e] &&
                   (eng_done_tag[e*TAGW +: TAGW] == tag_q[e]);
  wire [NENG-1:0] done_bad = eng_done & ~done_ok;

  // ---- one completion per cycle, round-robin --------------------------------
  wire [NENG-1:0] ready_set = pend_q | done_ok;

  // Round-robin pick. The wrap is a compare-and-subtract, NOT a modulo:
  // `(scan_i + rr_ptr) % NENG` made yosys build five 32-bit modulo-5
  // dividers -- 40,258 cells for a block with 35 flip-flops, found when the
  // ECP5 system build jumped to 57% of the device and per-module area
  // measurement pointed here. The loop itself is fine: it unrolls, so
  // scan_i is constant in each copy and the add is a few gates.
  logic            take_any;
  integer          take_i, scan_i, scan_e;
  wire [ENGW-1:0]  take_e = take_i[ENGW-1:0];

  always_comb begin
    take_any = 1'b0;
    take_i   = 0;
    // Scanning downwards leaves the LOWEST offset from rr_ptr selected,
    // which is the oldest turn in round-robin order.
    for (scan_i = NENG - 1; scan_i >= 0; scan_i = scan_i - 1) begin
      scan_e = scan_i + rr_ptr;
      if (scan_e >= NENG) scan_e = scan_e - NENG;
      if (ready_set[scan_e]) begin
        take_any = 1'b1;
        take_i   = scan_e;
      end
    end
  end

  assign comp_valid = take_any;
  assign comp_tag   = tag_q[take_e];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_q <= '0;
      pend_q <= '0;
      rr_ptr <= '0;
      err_bad_engine   <= 1'b0;
      err_done_unknown <= 1'b0;
      for (int e = 0; e < NENG; e++) tag_q[e] <= '0;
    end else begin
      err_bad_engine   <= bad;
      err_done_unknown <= |done_bad;

      if (fwd) begin
        busy_q[disp_engine] <= 1'b1;
        tag_q[disp_engine]  <= disp_tag;
      end

      for (int e = 0; e < NENG; e++) begin
        if (done_ok[e]) pend_q[e] <= 1'b1;
        if (take_any && (ENGW'(e) == take_e)) begin
          pend_q[e] <= 1'b0;
          busy_q[e] <= 1'b0;
        end
      end

      if (take_any) rr_ptr <= (take_e == ENGW'(NENG - 1)) ? '0 : take_e + ENGW'(1);
    end
  end

`ifdef FORMAL
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;
  always_comb if (!past_valid) assume (!rst_n);

  // Environment: a well-behaved engine reports done once, for the tag it was
  // given, while it holds it. Misbehaviour is what err_done_unknown reports,
  // and tb_mom_xbar drives it; the proofs here are about the honest case.
  always_comb
    for (int e = 0; e < NENG; e++)
      if (eng_done[e]) begin
        assume (busy_q[e] && !pend_q[e]);
        assume (eng_done_tag[e*TAGW +: TAGW] == tag_q[e]);
      end

  // X0: nothing is accepted or started while reset is asserted.
  always_comb if (!rst_n) begin
    assert (eng_valid == '0);
    assert (!disp_accept);
    assert (!comp_valid);
  end

  // X1: work is never sent to a busy engine.
  always_comb
    for (int e = 0; e < NENG; e++)
      if (eng_valid[e]) assert (!busy_q[e]);

  // X2: at most one engine is started per cycle.
  always_comb assert ($countones(eng_valid) <= 1);

  // X3: an out-of-range engine index is never forwarded, and is reported.
  always_comb if (disp_valid && !in_range) assert (eng_valid == '0);
  always_ff @(posedge clk)
    if (past_valid && rst_n && $past(rst_n) && $past(disp_valid) &&
        ($past(disp_engine) >= ENGW'(NENG)))
      assert (err_bad_engine);

  // X4: accept is asserted exactly when the descriptor leaves or is rejected.
  always_comb assert (disp_accept == (fwd || bad));

  // X5: an engine that has finished is still busy until it is reported, so a
  //     result can never be overwritten by new work.
  always_comb
    for (int e = 0; e < NENG; e++)
      if (pend_q[e]) assert (busy_q[e]);

  // X6: NO COMPLETION IS LOST. Every descriptor forwarded is either still
  //     executing, waiting to be reported, or being reported right now.
  integer started, retired;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin started <= 0; retired <= 0; end
    else begin
      if (fwd)        started <= started + 1;
      if (comp_valid) retired <= retired + 1;
    end
  always_comb assert (started - retired == $countones(busy_q));

  // X7: a completion is only presented for an engine that holds a tag.
  always_comb if (comp_valid) assert (busy_q[take_e]);

  // X8: the reported tag is the tag that engine was given.
  always_comb if (comp_valid) assert (comp_tag == tag_q[take_e]);

  always_ff @(posedge clk) if (past_valid) cover (comp_valid && $countones(pend_q) > 1);
  always_ff @(posedge clk) if (past_valid) cover ($countones(busy_q) == NENG);
`endif

endmodule

`default_nettype wire
