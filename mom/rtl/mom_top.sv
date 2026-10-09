/*
 * mom_top.sv
 *
 * HYDRA-130 - Mathematical Operation MUX, top level
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * PIPELINE
 * ===========================================================================
 *   cycle 1   mom_features     W, Q, log2(I)
 *   cycle 2   mom_cost_engine  five costs in parallel, one per engine
 *   cycle 3   mom_select       argmin, then allocate a tag and dispatch
 *
 * Three cycles from descriptor to dispatch. Software doing the same decision
 * costs 200 to 400 cycles: read the sizes, branch on op class, estimate, pick.
 * That is the two-orders-of-magnitude claim, and it is the reason this exists
 * in hardware at all.
 *
 * ===========================================================================
 * THE FEEDBACK LOOP
 * ===========================================================================
 *   dispatch --> engine runs --> completion --> scoreboard measures elapsed
 *                                                    |
 *                                          calibrate adjusts k
 *                                                    |
 *                                          cost engine reads k  <-- closes here
 *
 * The loop is entirely in hardware and needs no software involvement. That is
 * what makes the model self-tuning on workloads nobody characterized.
 * ===========================================================================
 */

`default_nettype none

// The cost-engine configuration is selected by a MACRO, not by a parameter
// override. sv2v resolves generate blocks while converting, using the
// parameter's DEFAULT: an override passed at instantiation was silently
// ignored, and tb_v1_v2_diff spent a run comparing the shared build against
// v1 and reporting 182,250 differences. A macro is decided before conversion
// and cannot be quietly dropped.
//   default (unset)            -> shared engine, what the tile ships
//   -DHYDRA_COST_SHARED=1'b0   -> five parallel engines, for the differential
`ifndef HYDRA_COST_SHARED
  `define HYDRA_COST_SHARED 1'b1
`endif

module mom_top
  import mom_pkg::*;
#(
  // ===========================================================================
  // COST_SHARED: one cost engine, walked over the engines, instead of five
  // ===========================================================================
  // Five parallel cost engines are 95,016 um^2 -- 39% of the tile, and the
  // reason the 4x4 harden ran out of room at 98.8% placement density. The
  // engines are IDENTICAL logic differing only in their inputs (ENGINE_ID is
  // declared but never used in the body), so one engine walked over the five
  // parameter rows computes the same five costs in more cycles and about a
  // fifth of the area. Measured: mom_top falls from 190,802 to ~117,665 um^2.
  //
  // TWO CYCLES PER ENGINE, not one. The engine is internally pipelined and
  // its second stage consumes k_cal -- the calibration factor, an INPUT --
  // alongside the registered first-stage result. Advancing every cycle would
  // multiply engine e's predicted time by engine e+1's calibration factor.
  // Holding each engine's inputs for two cycles is the cheap, obviously
  // correct fix; a skewed second select would save five cycles and is not
  // worth the subtlety here.
  //
  // COST_SHARED = 0 keeps the five parallel engines, which is what
  // tb_v1_v2_diff builds to prove the datapath is unchanged.
  parameter bit          COST_SHARED = `HYDRA_COST_SHARED,
  parameter int unsigned NTAG = 16,
  parameter int unsigned QMAX = 8
) (
  input  wire                clk,
  input  wire                rst_n,

  // ---- work descriptor in --------------------------------------------------
  input  wire                wd_valid,
  output wire                wd_ready,
  input  wire  work_desc_t   wd,

  // ---- dispatch out, to the engine crossbar --------------------------------
  output logic               disp_valid,
  input  wire                disp_accept,
  output logic [2:0]         disp_engine,
  output logic [3:0]         disp_tag,
  output work_desc_t         disp_wd,

  // ---- completion in -------------------------------------------------------
  input  wire                comp_valid,
  input  wire  [3:0]         comp_tag,

  // ---- fence ---------------------------------------------------------------
  input  wire  [3:0]         fence_tag,
  output wire                fence_busy,

  // ---- CSR -----------------------------------------------------------------
  input  wire                csr_wr,
  input  wire                csr_priv,
  input  wire  [2:0]         csr_engine,
  input  wire  [EPARAM_W-1:0] csr_data,
  input  wire  [3:0]         csr_bw_dma_log2,
  input  wire  [3:0]         csr_eps_mem,
  input  wire  [3:0]         csr_e_shift,
  input  wire                csr_cal_freeze,
  input  wire                csr_cal_reset,

  // ---- observability, mapped into the debug CSR block ----------------------
  // ---- error path ----------------------------------------------------------
  // Pulses for one cycle when a descriptor is discarded because no engine has
  // the capability to execute it. The descriptor's tag field is echoed so
  // software can match the error to the request. Without this the pipeline
  // would retry an unsatisfiable descriptor forever.
  output logic               err_unsupported,
  output logic [7:0]         err_tag,
  output wire                err_stale_comp,

  output wire  [COST_W-1:0]  obs_margin,
  output wire  [15:0]        obs_cal_updates,
  output wire  [NTAG-1:0]    obs_tag_busy
);

  // ===========================================================================
  // Stage 1: feature extraction
  // ===========================================================================
  logic              f_valid;
  logic              f_ready;
  work_desc_t        f_wd;
  logic [7:0]        f_lg_w, f_lg_q;
  logic signed [8:0] f_lg_i;

  mom_features u_feat (
    .clk(clk), .rst_n(rst_n),
    .in_valid(wd_valid), .in_ready(wd_ready), .in_wd(wd),
    .out_valid(f_valid), .out_ready(f_ready), .out_wd(f_wd),
    .out_log2_w(f_lg_w), .out_log2_q(f_lg_q), .out_log2_i(f_lg_i)
  );

  // ===========================================================================
  // Parameters, calibration, scoreboard
  // ===========================================================================
  eng_param_t [ENG_N-1:0] params;

  mom_param_rom u_prom (
    .clk(clk), .rst_n(rst_n),
    .wr_en(csr_wr), .wr_priv(csr_priv),
    .wr_engine(csr_engine), .wr_data(csr_data),
    .params(params)
  );

  logic [ENG_N-1:0][7:0] queue_depth;
  logic [ENG_N-1:0]      engine_full;
  logic              cal_valid;
  logic [2:0]        cal_engine;
  opclass_e          cal_opclass;
  logic [COST_W-1:0] cal_t_meas, cal_t_pred;

  // One shared calibration array with ENG_N parallel read ports. See the
  // header of mom_calibrate.sv for why this is not five instances.
  wire [ENG_N-1:0][7:0] k_cal;

  mom_calibrate u_cal (
    .clk(clk), .rst_n(rst_n),
    .freeze(csr_cal_freeze), .reset_factors(csr_cal_reset),
    .rd_opclass(f_wd.op_class), .rd_k(k_cal),
    .upd_valid(cal_valid), .upd_engine(cal_engine),
    .upd_opclass(cal_opclass),
    .upd_t_measured(cal_t_meas), .upd_t_predicted(cal_t_pred),
    .upd_count(obs_cal_updates), .last_dir()
  );

  // ===========================================================================
  // Stage 2: five cost engines in parallel
  // ===========================================================================
  // Driven by the engines in parallel mode, by lane registers in shared mode.
  logic [ENG_N-1:0][COST_W-1:0] cost;
  logic [ENG_N-1:0][COST_W-1:0] t_pred;
  logic [ENG_N-1:0]             cvalid;

  logic [ENG_N-1:0]             ccapable;

  // Shared-mode sequencer state, declared here so both branches can read it.
  logic                         eval_done;      // costs for all engines ready
  logic                         eval_busy;
  // The sweep writes the SELECTOR's registers directly. Lane registers of
  // its own would be the same 330 flip-flops twice: cost, predicted time,
  // valid and capable for five engines, held once by the sweep and again by
  // the cost register a cycle later. Writing in place is safe because a
  // sweep only starts when that register is free, and c_valid is low for its
  // whole duration, so the selector never reads a half-written set.
  logic                         lane_we;        // write one engine's result
  logic [2:0]                   lane_idx;
  logic [COST_W-1:0]            lane_cost, lane_tpred;
  logic                         lane_valid, lane_capable;

  generate
  if (!COST_SHARED) begin : g_parallel
    // ---- five engines, one cycle, bit-exact with v1 --------------------------
    for (genvar e = 0; e < ENG_N; e++) begin : g_cost
      mom_cost_engine #(.ENGINE_ID(engine_e'(e))) u_ce (
        .clk(clk), .rst_n(rst_n), .adv(a_adv),
        .log2_w(f_lg_w), .bytes_q(f_wd.bytes), .log2_i(f_lg_i),
        .dtype(f_wd.dtype), .op_class(f_wd.op_class), .lat_hint(f_wd.lat_hint),
        .lambda_sh(lambda_sh_of(f_wd.pwr_hint)),
        .param(params[e]), .k_cal(k_cal[e]),
        .queue_depth(queue_depth[e]), .engine_busy_full(engine_full[e]),
        .bw_dma_log2(csr_bw_dma_log2), .eps_mem(csr_eps_mem),
        .e_shift(csr_e_shift),
        .cost(cost[e]), .t_pred(t_pred[e]), .valid(cvalid[e]),
        .capable(ccapable[e])
      );
    end
    assign eval_done    = 1'b0;
    assign eval_busy    = 1'b0;
    assign lane_we      = 1'b0;
    assign lane_idx     = 3'd0;
    assign lane_cost    = '0;
    assign lane_tpred   = '0;
    assign lane_valid   = 1'b0;
    assign lane_capable = 1'b0;

  end else begin : g_shared
    // ---- one engine, walked over the five parameter rows ---------------------
    //   phase 0: present engine idx, advance -- stage A latches
    //   phase 1: same inputs held, stage B valid for idx -- capture it
    logic [2:0] idx;
    logic       phase;

    wire last = (idx == 3'(ENG_N - 1)) && phase;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        idx <= 3'd0; phase <= 1'b0; eval_busy <= 1'b0;
      end else if (!eval_busy) begin
        // Start only when stage A is free, so a finished set of costs is
        // never overwritten before the selector has taken it.
        if (f_valid && (!c_valid || c_ready)) begin
          eval_busy <= 1'b1; idx <= 3'd0; phase <= 1'b0;
        end
      end else if (last) begin
        eval_busy <= 1'b0; idx <= 3'd0; phase <= 1'b0;
      end else if (phase) begin
        phase <= 1'b0; idx <= idx + 3'd1;
      end else begin
        phase <= 1'b1;
      end
    end

    assign eval_done = eval_busy && last;

    logic [COST_W-1:0] s_cost, s_tpred;
    logic              s_valid, s_capable;

    mom_cost_engine #(.ENGINE_ID(ENG_CPU)) u_ce (
      .clk(clk), .rst_n(rst_n), .adv(eval_busy && !phase),
      .log2_w(f_lg_w), .bytes_q(f_wd.bytes), .log2_i(f_lg_i),
      .dtype(f_wd.dtype), .op_class(f_wd.op_class), .lat_hint(f_wd.lat_hint),
      .lambda_sh(lambda_sh_of(f_wd.pwr_hint)),
      .param(params[idx]), .k_cal(k_cal[idx]),
      .queue_depth(queue_depth[idx]), .engine_busy_full(engine_full[idx]),
      .bw_dma_log2(csr_bw_dma_log2), .eps_mem(csr_eps_mem),
      .e_shift(csr_e_shift),
      .cost(s_cost), .t_pred(s_tpred), .valid(s_valid), .capable(s_capable)
    );

    // Engine idx's result is valid in its second cycle; hand it to the cost
    // register, which stores it in place.
    assign lane_we      = eval_busy && phase;
    assign lane_idx     = idx;
    assign lane_cost    = s_cost;
    assign lane_tpred   = s_tpred;
    assign lane_valid   = s_valid;
    assign lane_capable = s_capable;
    assign cost = '0; assign t_pred = '0; assign cvalid = '0;
    assign ccapable = '0;
  end
  endgenerate

  // ===========================================================================
  // Stage 3: argmin
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Stage 2b (session 141): the cost register.
  //
  // The first harden of the TT tile put the whole feature -> five cost
  // engines -> argmin -> dispatch chain in ONE cycle: 98 cells, 32 ns at the
  // typical corner and 62 ns at ss_100C_1v60, where it violated setup by
  // 6.5 ns at a 55 ns period. No amount of buffering fixes a path that
  // long; the fix is a register in the middle. This stage captures the
  // engines' outputs (cost, t_pred, valid, capable) together with the
  // feature word they were computed from, and mom_select reads the
  // registered copy. Dispatch latency becomes four cycles instead of three,
  // which a roofline dispatcher does not notice.
  //
  // Handshake: a plain pipeline register that accepts when empty or when
  // stage 3 drains it. queue_depth/engine_full as seen by the cost engines
  // are one cycle old; that only shades the estimate, and the scoreboard's
  // own full check is on live state, so a full engine is still refused.
  // ---------------------------------------------------------------------------
  logic [ENG_N-1:0][COST_W-1:0] cost_q;
  logic [ENG_N-1:0][COST_W-1:0] t_pred_q;
  logic [ENG_N-1:0]             cvalid_q, ccapable_q;
  work_desc_t                   c_wd, a_wd;
  logic                         c_valid, a_valid;
  wire                          c_ready;                 // stage 3 drains us
  wire                          c_accept = !c_valid || c_ready;
  // Stage 2a (session 144): the cost engines' own mid-pipeline register.
  // a_valid says that register holds a descriptor; it advances when the
  // cost register can accept. Both stages move in lockstep on a_adv.
  wire                          a_adv    = !a_valid || c_accept;

  // Stage A load/clear. Parallel mode is the original behaviour written as
  // load/clear terms; shared mode loads when the sequencer finishes a full
  // sweep and clears when the selector takes the result.
  wire a_load  = COST_SHARED ? 1'b0                 : (a_adv && f_valid);
  wire a_clear = COST_SHARED ? 1'b0                 : (a_adv && !f_valid);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_valid <= 1'b0; a_wd <= '0;
    end else if (a_load) begin
      a_valid <= 1'b1;
      a_wd    <= f_wd;
    end else if (a_clear) begin
      a_valid <= 1'b0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_valid    <= 1'b0;
      cost_q     <= '0;
      t_pred_q   <= '0;
      cvalid_q   <= '0;
      ccapable_q <= '0;
      c_wd       <= '0;
    end else if (COST_SHARED) begin
      // One engine per two cycles, written straight into these registers.
      if (lane_we) begin
        cost_q[lane_idx]     <= lane_cost;
        t_pred_q[lane_idx]   <= lane_tpred;
        cvalid_q[lane_idx]   <= lane_valid;
        ccapable_q[lane_idx] <= lane_capable;
      end
      if (eval_done) begin
        c_valid <= 1'b1;
        c_wd    <= f_wd;
      end else if (c_ready) begin
        c_valid <= 1'b0;
      end
    end else if (c_accept) begin
      c_valid    <= a_valid;
      if (a_valid) begin
        cost_q     <= cost;              // stage B output for the a_wd descriptor
        t_pred_q   <= t_pred;
        cvalid_q   <= cvalid;
        ccapable_q <= ccapable;
        c_wd       <= a_wd;
      end
    end
  end

  logic [2:0]        sel_eng;
  logic [COST_W-1:0] sel_cost;
  logic              sel_ok;
  logic              sel_capable;

  mom_select u_sel (
    .cost(cost_q), .valid(cvalid_q), .capable(ccapable_q),
    .sel_engine(sel_eng), .sel_cost(sel_cost),
    .any_valid(sel_ok), .any_capable(sel_capable),
    .sel_margin(obs_margin)
  );

  // An unsatisfiable descriptor is consumed and reported, never retried.
  wire unsupported = c_valid && !sel_capable;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      err_unsupported <= 1'b0;
      err_tag         <= 8'd0;
    end else begin
      err_unsupported <= unsupported;
      if (unsupported) err_tag <= c_wd.tag;
    end
  end

  // ===========================================================================
  // Tag allocation and dispatch handshake
  // ===========================================================================
  wire sb_ready;

  mom_scoreboard #(.NTAG(NTAG), .QMAX(QMAX)) u_sb (
    .clk(clk), .rst_n(rst_n),
    .disp_valid(c_valid && sel_ok && disp_accept),
    .disp_ready(sb_ready),
    .disp_engine(sel_eng), .disp_opclass(c_wd.op_class),
    .disp_t_pred(t_pred_q[sel_eng]), .disp_tag(disp_tag),
    .comp_valid(comp_valid), .comp_tag(comp_tag),
    .cal_valid(cal_valid), .cal_engine(cal_engine),
    .cal_opclass(cal_opclass),
    .cal_t_measured(cal_t_meas), .cal_t_predicted(cal_t_pred),
    .queue_depth(queue_depth), .engine_full(engine_full),
    .fence_tag(fence_tag), .fence_busy(fence_busy),
    .err_stale_comp(err_stale_comp),
    .tag_busy_vec(obs_tag_busy)
  );

  // A descriptor advances only when an engine was selectable AND a tag was
  // available AND the crossbar accepted. Any of the three failing leaves it in
  // stage 1 to retry, which is why there is no separate stall FSM.
  assign disp_valid = c_valid && sel_ok && sb_ready;
  assign disp_engine = sel_eng;
  assign disp_wd     = c_wd;
  // Drain on a successful dispatch OR on an unsupported descriptor. The second
  // term is what breaks the livelock.
  assign c_ready     = (disp_valid && disp_accept) || unsupported;
  // The features stage may move on only when its descriptor has been
  // consumed: one cycle in parallel mode, the end of the sweep in shared.
  assign f_ready     = COST_SHARED ? eval_done : a_adv;

endmodule

`default_nettype wire
