/*
 * mom_scoreboard.sv
 *
 * HYDRA-130 - MOM outstanding-work tracker
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT MAKES THE CHIP CONCURRENT
 * ===========================================================================
 * Without this module MOM is a router: it picks an engine, the CPU waits, work
 * completes, repeat. One thing happens at a time.
 *
 * With it, dispatch is fire-and-forget. The CPU pushes a descriptor, gets a
 * tag back immediately, and keeps executing. Five engines run concurrently on
 * a single-core chip. That is the concurrency story, and it lives here.
 *
 * Three jobs:
 *
 *   1. OCCUPANCY. Per-engine outstanding counts, fed back to the cost engines
 *      as the queue-depth term in equation (5), and used to mask engines whose
 *      queues are full.
 *
 *   2. TAG BOOKKEEPING. Each in-flight operation holds its engine, op class,
 *      dispatch timestamp, and uncalibrated prediction. On completion these
 *      feed mom_calibrate.sv. Without the stored prediction there is nothing
 *      to compare the measurement against, and the calibration loop cannot
 *      close.
 *
 *   3. FENCE SUPPORT. `fence.acc` stalls on one specific tag rather than on
 *      all outstanding work. Waiting for everything would serialize the five
 *      engines back into one, which would undo the entire point.
 *
 * ===========================================================================
 * WHY 16 TAGS
 * ===========================================================================
 * Little's law bounds useful concurrency:
 *
 *     L = lambda * W
 *
 * where L is the number in flight, lambda the arrival rate, and W the mean
 * service time. With a dispatch every ~50 cycles and a mean service time of
 * ~400 cycles, L is about 8. Sixteen gives 2x headroom for bursts without
 * paying for tags that never fill.
 *
 * Sixteen tags x 56 bits = 896 flops, roughly 5,400 GE.
 * ===========================================================================
 */

`default_nettype none

module mom_scoreboard
  import mom_pkg::*;
#(
  parameter int unsigned NTAG = 16,
  parameter int unsigned QMAX = 8      // per-engine outstanding limit
) (
  input  wire                clk,
  input  wire                rst_n,

  // ---- dispatch ------------------------------------------------------------
  input  wire                disp_valid,
  output wire                disp_ready,
  input  wire  [2:0]         disp_engine,
  input  wire  opclass_e     disp_opclass,
  input  wire  [COST_W-1:0]  disp_t_pred,
  output logic [3:0]         disp_tag,

  // ---- completion, from the engines ----------------------------------------
  input  wire                comp_valid,
  input  wire  [3:0]         comp_tag,

  // ---- to mom_calibrate ----------------------------------------------------
  output logic               cal_valid,
  output logic [2:0]         cal_engine,
  output opclass_e           cal_opclass,
  output logic [COST_W-1:0]  cal_t_measured,
  output logic [COST_W-1:0]  cal_t_predicted,

  // ---- to the cost engines -------------------------------------------------
  output logic [ENG_N-1:0][7:0] queue_depth,
  output logic [ENG_N-1:0]      engine_full,

  // ---- fence ---------------------------------------------------------------
  input  wire  [3:0]         fence_tag,
  output wire                fence_busy,

  // ---- error ---------------------------------------------------------------
  // Pulses when a completion arrives for a tag that is not in flight. That is
  // a protocol violation on the engine side: a double completion, a completion
  // for a tag that was never dispatched, or a completion racing the dispatch
  // that allocated it.
  //
  // Silently ignoring it, which is what the first version did, is the worst
  // option available. The occupancy counter then never decrements, the engine
  // saturates at QMAX, and dispatch stops with no indication of why. That
  // failure took a waveform trace to find in simulation and would be far worse
  // in silicon. Reporting it costs one flop.
  output logic               err_stale_comp,

  // ---- observability -------------------------------------------------------
  output wire  [NTAG-1:0]    tag_busy_vec
);

  // ---------------------------------------------------------------------------
  // Free-running cycle counter. Dispatch and completion timestamps are
  // subtracted to measure service time. Wrap is harmless: the difference is
  // correct modulo 2^32, and no operation lives anywhere near 4 billion cycles.
  // ---------------------------------------------------------------------------
  logic [COST_W-1:0] now;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) now <= '0; else now <= now + 32'd1;

  // ---------------------------------------------------------------------------
  // Tag table
  // ---------------------------------------------------------------------------
  logic              busy    [NTAG];
  logic [2:0]        t_eng   [NTAG];
  opclass_e          t_opc   [NTAG];
  logic [COST_W-1:0] t_start [NTAG];
  logic [COST_W-1:0] t_pred  [NTAG];

  for (genvar t = 0; t < NTAG; t++) begin : g_busyvec
    assign tag_busy_vec[t] = busy[t];
  end

  // Lowest free tag. A priority encoder over 16 bits, about 40 gates.
  logic [3:0] free_tag;
  logic       have_free;
  always_comb begin
    free_tag  = 4'd0;
    have_free = 1'b0;
    for (int t = NTAG - 1; t >= 0; t--)
      if (!busy[t]) begin
        free_tag  = 4'(t);
        have_free = 1'b1;
      end
  end

  // ---------------------------------------------------------------------------
  // PORT RANGE GUARDS
  //
  // `disp_engine` is 3 bits and ENG_N is 5. `comp_tag` is 4 bits and NTAG may
  // be 4, 8, or 16. Both ports can therefore carry values that index past the
  // end of their arrays, and an out-of-range index is undefined rather than
  // merely wrong.
  //
  // A formal proof found this. In the integrated SoC it is unreachable, because
  // mom_select only ever emits 0..4 and the CPU only ever completes tags it was
  // given. But that is an undocumented invariant spanning modules, and it is
  // NOT unreachable on the TinyTapeout tile: there the host drives comp_tag
  // straight from four pins, so tags 8 through 15 with NTAG = 8 are one typo
  // away in the driver script.
  //
  // Guarding costs two comparators. Not guarding costs a chip that behaves
  // unpredictably when software makes a mistake, which is exactly when you most
  // want it not to.
  // ---------------------------------------------------------------------------
  wire disp_engine_ok = (disp_engine < 3'(ENG_N));
  wire comp_tag_ok    = ({28'd0, comp_tag} < NTAG);

  wire engine_has_room = disp_engine_ok && !engine_full[disp_engine];
  assign disp_ready = have_free && engine_has_room;
  assign disp_tag   = free_tag;

  wire do_disp = disp_valid && disp_ready;
  wire do_comp = comp_valid && comp_tag_ok && busy[comp_tag];

  // A completion whose tag is out of range, or in range but not busy, is
  // dropped. Dropping it silently is what breaks the occupancy counter, so it
  // is reported instead. Out-of-range counts as stale: the tag was certainly
  // never dispatched.
  wire stale_comp = comp_valid && (!comp_tag_ok || !busy[comp_tag]);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) err_stale_comp <= 1'b0;
    else        err_stale_comp <= stale_comp;

  // ---------------------------------------------------------------------------
  // Occupancy counters.
  //
  // Dispatch and completion can hit the same engine on the same cycle, so the
  // increment and decrement are combined rather than sequenced. Getting this
  // wrong produces a counter that drifts upward over hours until every engine
  // looks permanently full, which is a miserable bug to find in silicon.
  // ---------------------------------------------------------------------------
  for (genvar e = 0; e < ENG_N; e++) begin : g_queue
    wire inc = do_disp && (disp_engine == 3'(e));
    wire dec = do_comp && (t_eng[comp_tag] == 3'(e));

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n)
        queue_depth[e] <= 8'd0;
      else if (inc && !dec)
        queue_depth[e] <= queue_depth[e] + 8'd1;
      else if (dec && !inc && (queue_depth[e] != 8'd0))
        queue_depth[e] <= queue_depth[e] - 8'd1;
    end

    assign engine_full[e] = (queue_depth[e] >= 8'(QMAX));
  end

  // ---------------------------------------------------------------------------
  // Tag allocation and retirement
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int t = 0; t < NTAG; t++) begin
        busy[t]    <= 1'b0;
        t_eng[t]   <= 3'd0;
        t_opc[t]   <= OPC_SCALAR;
        t_start[t] <= '0;
        t_pred[t]  <= '0;
      end
    end else begin
      if (do_disp) begin
        busy[free_tag]    <= 1'b1;
        t_eng[free_tag]   <= disp_engine;
        t_opc[free_tag]   <= disp_opclass;
        t_start[free_tag] <= now;
        t_pred[free_tag]  <= disp_t_pred;
      end
      if (do_comp)
        busy[comp_tag] <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Feed the calibrator. Measured service time is the timestamp difference.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cal_valid <= 1'b0;
    end else begin
      cal_valid       <= do_comp;
      cal_engine      <= t_eng[comp_tag];
      cal_opclass     <= t_opc[comp_tag];
      cal_t_measured  <= now - t_start[comp_tag];
      cal_t_predicted <= t_pred[comp_tag];
    end
  end

  assign fence_busy = busy[fence_tag];

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // A tag is never allocated twice.
  //
  // The natural phrasing, `assert ($past(busy[$past(free_tag)]) == 0)`, is a
  // $past of an array element selected by a $past index. That is a nested
  // sampled expression with a variable index and it is not expressible; the
  // same trap appeared in mom_param_rom.sv.
  //
  // Stated combinationally instead: the tag being handed out is, by definition
  // of free_tag, one that is currently free. Checking it at the moment of
  // allocation is both simpler and strictly stronger than checking it a cycle
  // later.
  // ---------------------------------------------------------------------------
  always @(*) begin
    if (rst_n && do_disp) assert (busy[free_tag] == 1'b0);
  end

  // have_free must agree with the busy vector. If this ever fails, the
  // priority encoder and the array have diverged.
  always @(*) begin
    if (rst_n && !have_free)
      for (int t = 0; t < NTAG; t++) assert (busy[t]);
  end

  // Occupancy never exceeds the tag count. If this fails, the increment and
  // decrement logic above has the simultaneous case wrong.
  always @(*) begin
    if (rst_n)
      for (int e = 0; e < ENG_N; e++)
        assert (queue_depth[e] <= 8'(NTAG));
  end

  // Dispatch is refused when the chosen engine is full, and also when the
  // engine index is out of range. The second half is the property whose
  // absence the guards above now fix.
  always @(*) begin
    if (rst_n && disp_engine_ok && engine_full[disp_engine])
      assert (!disp_ready);
    if (rst_n && !disp_engine_ok)
      assert (!disp_ready);
  end

  // An out-of-range completion must be flagged, never acted on.
  always @(*) begin
    if (rst_n && comp_valid && !comp_tag_ok) assert (stale_comp && !do_comp);
  end
`endif

endmodule

`default_nettype wire
