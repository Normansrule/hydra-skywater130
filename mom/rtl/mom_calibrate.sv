/*
 * mom_calibrate.sv
 *
 * HYDRA-130 - MOM online cost-model calibration
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * THIS IS THE NOVEL PART
 * ===========================================================================
 * An analytical cost model is cheap and always wrong. The parameters in
 * mom_param_rom.sv are pre-silicon estimates, the log-domain arithmetic in
 * mom_cost_engine.sv throws away mantissas, and no static model anticipates
 * cache state, DVFS, or a workload nobody characterized.
 *
 * So this module watches what actually happened and corrects the model.
 *
 * For each (engine, operation class) pair it keeps an 8-bit Q2.6 factor k:
 *
 *     T_calibrated = k * T_predicted / 64
 *
 * with k = 64 meaning "the analytical model was exactly right", k = 32 meaning
 * "the engine was twice as fast as predicted", and k = 255 meaning "about four
 * times slower". The format was widened from Q1.7 after the closed-loop
 * testbench showed a 1.99x ceiling saturating on plausible hardware; see
 * mom_pkg.sv for the full reasoning.
 *
 * 5 engines x 9 op classes x 8 bits = 360 flops, plus update logic.
 * About 2,900 GE total.
 *
 * ===========================================================================
 * THE UPDATE RULE, AND WHY IT IS NOT AN EWMA
 * ===========================================================================
 * The natural formulation is an exponentially weighted moving average on the
 * ratio of measured to predicted:
 *
 *     k <- k + (1/2^alpha) * ( 64 * T_measured / T_predicted  -  k )    ... (A)
 *
 * That is correct and it needs a 32-bit divider. A divider is roughly 2,500
 * gates and would nearly double this module.
 *
 * The divider is avoidable. Note that we do not need the magnitude of the
 * error, only its sign, if the step size is made proportional to k itself:
 *
 *     err  = T_measured - T_calibrated
 *     step = max(1, k >> alpha)
 *     k   <- k + sign(err) * step                                       ... (B)
 *
 * This is sign-LMS with a multiplicative step. Two properties make it work:
 *
 *   1. FIXED POINT. k stops moving on average only when err changes sign
 *      equally often in both directions, which happens exactly when
 *      T_calibrated tracks the median of T_measured. That is the value we
 *      want, and it is more robust to outliers than the mean that (A) finds.
 *
 *   2. GEOMETRIC CONVERGENCE. Because step scales with k, the relative change
 *      per update is constant at about 1/2^alpha. With alpha = 4 that is 6.25%
 *      per update, so correcting a 2x model error takes
 *
 *          n = ln(2) / ln(1 + 1/16) = 11.4  ->  about 12 updates
 *
 *      At even a modest thousand dispatches per second, convergence is
 *      effectively instantaneous.
 *
 * The cost of (B) over (A) is slower convergence and dither of one step
 * around the fixed point. Both are irrelevant here, and the divider is gone.
 * Total update logic: a subtract, a shift, a comparator, and an add.
 *
 * ===========================================================================
 * WHY PER OP CLASS AND NOT JUST PER ENGINE
 * ===========================================================================
 * The same engine mispredicts differently on different work. The TPU's model
 * is nearly exact on a large GEMM, where the systolic pipeline is full and the
 * closed-form cycle count holds. On a small convolution the drain and fill
 * overheads dominate and the model can be 3x optimistic.
 *
 * One k per engine would average those into a factor that is wrong for both.
 * Nine op classes cost 8x the flops and remove the averaging entirely.
 *
 * ===========================================================================
 * SATURATION AND SANITY
 * ===========================================================================
 * k is clamped to [K_MIN, K_MAX] = [4, 255], that is [0.0625, 3.98] in Q2.6.
 * The clamp is a safety property, not an optimization. A runaway k near zero
 * would make one engine look free and every descriptor would pile onto it,
 * which is a self-reinforcing failure: the queue grows, measurements get
 * worse, and if the sign convention were ever inverted the loop would diverge.
 * The floor makes that impossible.
 *
 * `freeze` stops all adaptation. Set it during characterization runs so the
 * measured numbers reflect the analytical model alone, and during any
 * real-time critical section where a changing dispatch policy would perturb
 * worst-case latency analysis.
 * ===========================================================================
 */

`default_nettype none

module mom_calibrate
  import mom_pkg::*;
#(
  // EWMA-equivalent shift. Larger = slower, smoother adaptation.
  //   alpha=3  12.5% per update, ~6 updates to correct 2x
  //   alpha=4   6.25%            ~12 updates      (default)
  //   alpha=6   1.56%            ~45 updates
  parameter int unsigned ALPHA = 4,   // = KCAL_ALPHA in mom_pkg
  parameter logic [7:0]  K_MIN = 8'd4,
  parameter logic [7:0]  K_MAX = 8'd255
) (
  input  wire                clk,
  input  wire                rst_n,

  // ---- control -------------------------------------------------------------
  input  wire                freeze,        // 1 = hold all factors
  input  wire                reset_factors, // 1 = force every k back to unity

  // ---- lookup, combinational, one port per engine ---------------------------
  // All five cost engines evaluate the SAME descriptor simultaneously, so they
  // all want the same op class and differ only in engine index. Exposing five
  // parallel read ports on one shared array is therefore the natural shape.
  //
  // The first version of mom_top instead instantiated five read-only copies of
  // this module, which replicated the 360-flop storage array five times and
  // wasted about 1,440 flops (roughly 8,600 GE, 0.07 mm²). Worse, the copies
  // were frozen, so four of the five held stale unity factors and the
  // calibration loop silently did nothing for four engines out of five.
  input  wire  opclass_e            rd_opclass,
  output wire  [ENG_N-1:0][7:0]     rd_k,

  // ---- update port, one completion per cycle at most -----------------------
  input  wire                upd_valid,
  input  wire  [2:0]         upd_engine,
  input  wire  opclass_e     upd_opclass,
  input  wire  [COST_W-1:0]  upd_t_measured,   // actual cycles, from scoreboard
  input  wire  [COST_W-1:0]  upd_t_predicted,  // uncalibrated T_hat at dispatch

  // ---- observability -------------------------------------------------------
  output logic [15:0]        upd_count,
  output logic               last_dir          // 1 = k increased
);

  localparam int unsigned NOPC = 9;   // opclass_e cardinality

  logic [7:0] k [ENG_N][NOPC];

  // ---------------------------------------------------------------------------
  // Read port. Guarded so an out-of-range index returns unity rather than X,
  // which matters because this feeds a multiplier in the cost engine.
  // ---------------------------------------------------------------------------
  // Guarded so an out-of-range op class returns unity rather than X. This
  // feeds a multiplier in the cost engine, and an X there would propagate into
  // the comparison tree and make the dispatch decision nondeterministic.
  for (genvar e = 0; e < ENG_N; e++) begin : g_rd
    assign rd_k[e] = (rd_opclass < opclass_e'(NOPC)) ? k[e][rd_opclass]
                                                     : KCAL_UNITY;
  end

  // ---------------------------------------------------------------------------
  // The update, equation (B).
  //
  // T_calibrated is recomputed here rather than carried from dispatch, because
  // k may have moved between dispatch and completion. Comparing against the
  // stale value would make the loop chase its own tail.
  // ---------------------------------------------------------------------------
  wire [7:0] k_cur = (upd_engine < 3'(ENG_N) && upd_opclass < opclass_e'(NOPC))
                   ? k[upd_engine][upd_opclass]
                   : KCAL_UNITY;

  wire [39:0]       t_cal_wide = upd_t_predicted * {32'd0, k_cur};
  wire [COST_W-1:0] t_cal      = t_cal_wide[COST_W+KCAL_SHIFT-1 -: COST_W];

  // Sign of the error. Ties do not move k, which kills dither at the fixed
  // point when a workload is perfectly predicted.
  wire too_slow = (upd_t_measured > t_cal);   // model was optimistic, raise k
  wire too_fast = (upd_t_measured < t_cal);   // model was pessimistic, lower k

  // ---------------------------------------------------------------------------
  // The update arithmetic lives in a function so the datapath below and the
  // formal free-input check at the bottom of this file use LITERALLY the same
  // logic. Duplicating it would let the property drift away from the design,
  // which is a slower and more embarrassing failure than having no property.
  // ---------------------------------------------------------------------------
  function automatic logic [7:0] step_of(input logic [7:0] kc);
    logic [7:0] raw;
    begin
      raw     = kc >> ALPHA;
      // Floored at 1 so adaptation never stalls at small k.
      step_of = (raw == 8'd0) ? 8'd1 : raw;
    end
  endfunction

  function automatic logic [7:0] k_up_of(input logic [7:0] kc);
    logic [8:0] w;
    begin
      w       = {1'b0, kc} + {1'b0, step_of(kc)};
      k_up_of = (w > {1'b0, K_MAX}) ? K_MAX : w[7:0];
    end
  endfunction

  function automatic logic [7:0] k_dn_of(input logic [7:0] kc);
    logic [8:0] w;
    begin
      w       = {1'b0, kc} - {1'b0, step_of(kc)};
      k_dn_of = (w[8] || (w[7:0] < K_MIN)) ? K_MIN : w[7:0];
    end
  endfunction

  wire [7:0] step   = step_of(k_cur);
  wire [7:0] k_up   = k_up_of(k_cur);
  wire [7:0] k_dn   = k_dn_of(k_cur);
  wire [7:0] k_next = too_slow ? k_up : (too_fast ? k_dn : k_cur);

  // A prediction of zero is meaningless and would divide the model by nothing.
  // Skip the update rather than corrupt k.
  wire do_update = upd_valid && !freeze && (upd_t_predicted != '0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int e = 0; e < ENG_N; e++)
        for (int c = 0; c < NOPC; c++)
          k[e][c] <= KCAL_UNITY;
      upd_count <= 16'd0;
      last_dir  <= 1'b0;
    end else if (reset_factors) begin
      for (int e = 0; e < ENG_N; e++)
        for (int c = 0; c < NOPC; c++)
          k[e][c] <= KCAL_UNITY;
      upd_count <= 16'd0;
    end else if (do_update) begin
      k[upd_engine][upd_opclass] <= k_next;
      upd_count                  <= upd_count + 16'd1;
      last_dir                   <= too_slow;
    end
  end

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // THE INDUCTIVE STEP, checked over a FREE value of k.
  //
  // Session 9 asserted `k_next >= K_MIN && k_next <= K_MAX` and described it as
  // "exhaustive over all 256 cases". That description was WRONG, and mutation
  // testing in session 22 proved it: `k_cur` is not a free input, it reads the
  // stored array, so a bounded-from-reset run only ever presents values the
  // design can reach within the bound. Starting at KCAL_UNITY = 64, no short
  // BMC can walk k down to where the K_MIN clamp or the zero-step floor
  // matters. Deleting either guard left the proof passing.
  //
  // `$anyconst` fixes it. f_k_free is an unconstrained 8-bit value, so the
  // assertions below genuinely cover all 256 possibilities and the inductive
  // step is proved for real.
  //
  // The lesson generalizes: a combinational property is exhaustive only over
  // its FREE inputs. Reading registered state silently narrows it to the
  // reachable set, and nothing in the tool output says so.
  // ---------------------------------------------------------------------------
  (* anyconst *) wire [7:0] f_k_free;

  wire [7:0] f_k_up = k_up_of(f_k_free);
  wire [7:0] f_k_dn = k_dn_of(f_k_free);

  // Written as an IMPLICATION rather than an assume-plus-assert.
  //
  // The invariant is conditional and the first attempt got it wrong: asserting
  // the clamp unconditionally fails at f_k_free = 0, because k_up_of(0) = 1
  // which is below K_MIN. That is correct design behaviour, not a bug --
  // incrementing clamps only at the TOP, since a value already in range cannot
  // fall below the floor by going up. The property, not the design, was wrong.
  //
  // An implication also avoids an `assume`, which matters at integration level:
  // `chformal -assume2assert` would turn the precondition into an obligation on
  // mom_top, and mom_top has no way to constrain an $anyconst. Stating it as
  // an implication makes the property self-contained at every level.
  always @(*) begin
    if ((f_k_free >= K_MIN) && (f_k_free <= K_MAX)) begin
      assert (f_k_up >= K_MIN && f_k_up <= K_MAX);
      assert (f_k_dn >= K_MIN && f_k_dn <= K_MAX);
    end
    // The step floor holds unconditionally, including at k = 0.
    assert (step_of(f_k_free) != 8'd0);
  end

  // The reachable path, which now follows from the above plus the reset value.
  always @(*) begin
    assert (k_next >= K_MIN && k_next <= K_MAX);
  end

  // The stored invariant. Bounded from reset; see the note above for why this
  // one cannot be proved by induction alone.
  always @(*) begin
    if (rst_n)
      for (int e = 0; e < ENG_N; e++)
        for (int c = 0; c < NOPC; c++)
          assert (k[e][c] >= K_MIN && k[e][c] <= K_MAX);
  end

  // freeze must mean freeze.
  always @(posedge clk) begin
    if (rst_n && $past(rst_n) && $past(freeze) && !$past(reset_factors))
      for (int e = 0; e < ENG_N; e++)
        for (int c = 0; c < NOPC; c++)
          assert (k[e][c] == $past(k[e][c]));
  end

  // The step on the reachable path. The free-input version above is the one
  // that actually covers the small-k region.
  always @(*) begin
    if (rst_n) assert (step != 8'd0);
  end
`endif

endmodule

`default_nettype wire
