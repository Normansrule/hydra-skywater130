/*
 * mom_select.sv
 *
 * HYDRA-130 - MOM pipeline stage 3: argmin over engine costs
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT THIS DOES
 * ===========================================================================
 * Five 32-bit costs in, one 3-bit engine index out. That is the whole job.
 *
 *     e* = argmin_e  J_e     subject to  valid_e
 *
 * Implemented as a balanced comparator tree rather than a linear chain, so
 * depth is ceil(log2(5)) = 3 comparators instead of 4. At 32 bits each that is
 * roughly 3 x 0.9 ns of logic in sky130, which fits comfortably inside a
 * 10 ns period alongside the register setup.
 *
 * ===========================================================================
 * TIE-BREAK POLICY, AND WHY IT IS THE CPU
 * ===========================================================================
 * Ties resolve to the LOWER engine index, and ENG_CPU is index 0. This is a
 * deliberate safety choice, not an arbitrary one.
 *
 * The CPU is the only engine guaranteed to be correct for every descriptor.
 * It handles every dtype, it needs no setup, and it cannot deadlock waiting on
 * a weight load. When the cost model cannot distinguish two options, falling
 * back to the general-purpose engine is the conservative answer.
 *
 * It also gives a clean degenerate behaviour: if the parameter ROM were
 * misprogrammed so that every cost came out equal, the chip would still run
 * correctly, just without acceleration. A tie-break favouring the TPU would
 * instead route scalar control code into a systolic array.
 *
 * ===========================================================================
 * THE ALL-INVALID CASE
 * ===========================================================================
 * If every engine is masked out, `any_valid` deasserts and the caller stalls
 * the descriptor in the input FIFO to retry next cycle. We do NOT emit a
 * default choice. Dispatching to a full queue or a dtype-incompatible engine
 * would be a correctness bug, and stalling for a cycle is free by comparison.
 *
 * Because ENG_CPU is only ever masked when its queue is full, and the CPU
 * queue drains every cycle it is not stalled, this condition is transient by
 * construction. There is no livelock.
 * ===========================================================================
 */

`default_nettype none

module mom_select
  import mom_pkg::*;
#(
  // The runner-up margin needs a SECOND full comparator tree, measured at
  // roughly 900 cells. It is a diagnostic: it tells software how confident a
  // dispatch decision was, and a near-zero margin across many descriptors
  // means the cost model is not discriminating and the parameters need
  // retuning.
  //
  // That is valuable on a research chip and dead weight in a production
  // configuration, so it is a parameter rather than an assumption. With
  // WANT_MARGIN = 0 the second tree is not built at all and sel_margin reads
  // zero.
  parameter bit WANT_MARGIN = 1
) (
  input  wire  [ENG_N-1:0][COST_W-1:0] cost,
  input  wire  [ENG_N-1:0]             valid,
  input  wire  [ENG_N-1:0]             capable,

  output logic [2:0]         sel_engine,
  output logic [COST_W-1:0]  sel_cost,
  output logic               any_valid,
  // Deasserts when NO engine could ever execute this descriptor. The caller
  // must retire it with an error rather than retrying, or the pipeline hangs.
  output logic               any_capable,

  // Margin between the winner and the runner-up. Software reads this to see
  // how confident a dispatch decision was. A near-zero margin across many
  // descriptors means the cost model is not discriminating, which is a signal
  // that the parameters need retuning.
  output logic [COST_W-1:0]  sel_margin
);

  // ---------------------------------------------------------------------------
  // Lane packing: {NOT valid, cost, index}
  //
  // The index rides along in the low bits so the comparator tree carries it for
  // free, and the INVERTED valid bit rides in the top bit so that any invalid
  // engine compares greater than any valid one, whatever its cost.
  //
  // The first version instead assigned all-ones cost to invalid engines and
  // relied on that losing every comparison. A formal proof with Yosys found the
  // hole in about a second:
  //
  //     engine A valid   with cost = 0xFFFFFFFF
  //     engine B invalid with cost = anything
  //
  // Both lanes then hold all-ones, the tie breaks by index, and if B has the
  // lower index the selector returns an INVALID engine. The assertion
  // `valid[sel_engine]` fails.
  //
  // In the integrated design this is unreachable today, because
  // mom_cost_engine clamps a valid cost at COST_SAT = 0xFFFF0000 and never
  // emits 0xFFFFFFFF. But that is an undocumented invariant spanning two
  // modules, and it would break silently the day someone widens COST_SAT or
  // adds an engine that saturates differently. Simulation would not have found
  // it, because the stimulus that triggers it cannot be produced by the real
  // cost engines.
  //
  // Making validity part of the comparison key removes the invariant entirely.
  // Cost: one extra bit on each of six 35-bit comparators, about 30 cells.
  // ---------------------------------------------------------------------------
  localparam int unsigned PW = 1 + COST_W + 3;

  logic [PW-1:0] lane [ENG_N];

  for (genvar e = 0; e < ENG_N; e++) begin : g_pack
    assign lane[e] = { ~valid[e], cost[e], 3'(e) };
  end

  // Lower index wins ties: with the index in the low bits, a tie on cost is
  // broken by the index comparison automatically, and `<=` on the packed value
  // does exactly the right thing.
  // Compares {invalid, cost} as one unsigned key, so invalidity dominates cost
  // and cost dominates nothing else. Ties fall through to the index in the low
  // bits, and `<=` keeps the lower index.
  function automatic logic [PW-1:0] pick(input logic [PW-1:0] a,
                                         input logic [PW-1:0] b);
    pick = (a[PW-1:3] <= b[PW-1:3]) ? a : b;
  endfunction

  // ---------------------------------------------------------------------------
  // Level 1: (0,1) and (2,3), lane 4 passes through
  // Level 2: winners of level 1
  // Level 3: against lane 4
  // ---------------------------------------------------------------------------
  wire [PW-1:0] l1_a = pick(lane[0], lane[1]);
  wire [PW-1:0] l1_b = pick(lane[2], lane[3]);
  wire [PW-1:0] l2   = pick(l1_a, l1_b);
  wire [PW-1:0] best = pick(l2, lane[4]);

  // ---------------------------------------------------------------------------
  // Runner-up. Computed by re-running the tree with the winner masked out.
  // Costs a second tree, about 600 GE. Worth it: the margin is the single most
  // useful diagnostic when a dispatch decision looks wrong in silicon, and
  // this chip is a research vehicle.
  // ---------------------------------------------------------------------------
  wire [PW-1:0] snd;

  if (WANT_MARGIN) begin : g_margin
    logic [PW-1:0] lane2 [ENG_N];
    for (genvar e = 0; e < ENG_N; e++) begin : g_pack2
      // Mask the winner by forcing its invalid bit, which is the reliable way
      // to make a lane lose rather than hoping all-ones cost is unreachable.
      assign lane2[e] = (3'(e) == best[2:0]) ? {1'b1, cost[e], 3'(e)} : lane[e];
    end

    wire [PW-1:0] m1_a = pick(lane2[0], lane2[1]);
    wire [PW-1:0] m1_b = pick(lane2[2], lane2[3]);
    wire [PW-1:0] m2   = pick(m1_a, m1_b);
    assign snd = pick(m2, lane2[4]);
  end else begin : g_no_margin
    // Invalid-flagged so the margin computation below yields zero without
    // needing a separate branch there.
    assign snd = {1'b1, {COST_W{1'b0}}, 3'd0};
  end

  always_comb begin
    any_valid   = |valid;
    any_capable = |capable;
    sel_engine = best[2:0];
    sel_cost   = best[PW-2:3];        // drop the validity bit
    // Margin is only meaningful when the runner-up is itself valid. Reporting
    // a margin against an invalid lane would show a huge number and read as
    // "very confident" when it actually means "no alternative existed".
    sel_margin = (snd[PW-1] || !any_valid) ? '0
               : (snd[PW-2:3] >= best[PW-2:3])
                 ? (snd[PW-2:3] - best[PW-2:3])
                 : '0;
  end

`ifdef FORMAL
  // The winner must be valid whenever anything is.
  always @(*) begin
    if (any_valid) assert (valid[sel_engine]);
  end

  // The winner's cost must be minimal over the valid set. This is the
  // specification of the module, checked exhaustively rather than sampled.
  always @(*) begin
    if (any_valid)
      for (int e = 0; e < ENG_N; e++)
        if (valid[e]) assert (sel_cost <= cost[e]);
  end

  // Tie-break: no valid engine with a lower index may share the winning cost.
  always @(*) begin
    if (any_valid)
      for (int e = 0; e < ENG_N; e++)
        if (valid[e] && (3'(e) < sel_engine)) assert (cost[e] > sel_cost);
  end
`endif

endmodule

`default_nettype wire
