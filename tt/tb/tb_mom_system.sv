// =============================================================================
// tb_mom_system.sv -- the dispatcher, the crossbar and five engines
// =============================================================================
// This is the first time in this project that a dispatch actually REACHES an
// engine and the engine's own completion feeds the calibration. Until now the
// loop closed only because a testbench or a host wrote COMP.
//
// The engines are latency models, not implementations: each takes work, waits
// a programmable number of cycles, and reports done. That is exactly the part
// of an engine the roofline model claims to predict, so it is the part worth
// modelling before the engines exist.
//
// What this proves:
//   1. work dispatched by the MOM arrives at the engine the MOM chose;
//   2. every dispatch is completed exactly once, with the right tag;
//   3. the calibration loop converges with NO host in the loop: make the TPU
//      model slow and the decision leaves the TPU on its own.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_mom_system;
  import mom_pkg::*;

  localparam int NENG = 5, NTAG = 8;
  localparam int ENG_CPU = 0, ENG_SIMD = 1, ENG_TPU = 2;

  logic clk = 0, rst_n = 0;
  always #27.5 clk = ~clk;

  // ---- dispatcher ----------------------------------------------------------
  logic            wd_valid, wd_ready;
  work_desc_t      wd;
  logic            disp_valid, disp_accept;
  logic [2:0]      disp_engine;
  logic [3:0]      disp_tag;
  work_desc_t      disp_wd;
  logic            comp_valid;
  logic [3:0]      comp_tag;
  logic            err_unsupported, err_stale_comp;
  logic [7:0]      err_tag;
  logic [COST_W-1:0] obs_margin;
  logic [15:0]     obs_cal_updates;
  logic [NTAG-1:0] obs_tag_busy;
  logic            fence_busy;

  mom_top #(.NTAG(NTAG), .QMAX(4)) u_mom (
    .clk(clk), .rst_n(rst_n),
    .wd_valid(wd_valid), .wd_ready(wd_ready), .wd(wd),
    .disp_valid(disp_valid), .disp_accept(disp_accept),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(comp_valid), .comp_tag(comp_tag),
    .fence_tag(4'd0), .fence_busy(fence_busy),
    .csr_wr(1'b0), .csr_priv(1'b0), .csr_engine(3'd0), .csr_data('0),
    .csr_bw_dma_log2(4'd4), .csr_eps_mem(4'd12), .csr_e_shift(4'd8),
    .csr_cal_freeze(1'b0), .csr_cal_reset(1'b0),
    .err_unsupported(err_unsupported), .err_tag(err_tag),
    .err_stale_comp(err_stale_comp), .obs_margin(obs_margin),
    .obs_cal_updates(obs_cal_updates), .obs_tag_busy(obs_tag_busy));

  // ---- crossbar ------------------------------------------------------------
  logic [NENG-1:0]      eng_valid, eng_ready, eng_done, eng_busy;
  logic [WD_W-1:0]      eng_wd;
  logic [NENG*4-1:0]    eng_tag, eng_done_tag;
  logic err_bad_engine, err_done_unknown;

  mom_xbar #(.NENG(NENG), .NTAG(NTAG), .WD_W(WD_W), .TAGW(4), .ENGW(3)) u_xbar (
    .clk(clk), .rst_n(rst_n),
    .disp_valid(disp_valid), .disp_accept(disp_accept),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(comp_valid), .comp_tag(comp_tag),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .eng_busy(eng_busy), .err_bad_engine(err_bad_engine),
    .err_done_unknown(err_done_unknown));

  // ---- engine latency models -----------------------------------------------
  integer lat [NENG];                 // cycles each engine takes
  integer cnt [NENG];
  logic [3:0] held [NENG];
  integer finished [NENG];

  genvar g;
  generate
    for (g = 0; g < NENG; g++) begin : g_eng
      assign eng_ready[g] = (cnt[g] == 0);
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          cnt[g] <= 0; eng_done[g] <= 1'b0; held[g] <= 4'd0;
        end else begin
          eng_done[g] <= 1'b0;
          if (eng_valid[g]) begin
            cnt[g]  <= lat[g];
            held[g] <= eng_tag[g*4 +: 4];
          end else if (cnt[g] > 1) begin
            cnt[g] <= cnt[g] - 1;
          end else if (cnt[g] == 1) begin
            cnt[g]      <= 0;
            eng_done[g] <= 1'b1;
          end
        end
      end
      assign eng_done_tag[g*4 +: 4] = held[g];
    end
  endgenerate

  // Counted here rather than inside the generate block: sv2v flattens
  // generates and hierarchical references into them stop resolving.
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) for (int e = 0; e < NENG; e++) finished[e] <= 0;
    else        for (int e = 0; e < NENG; e++) if (eng_done[e]) finished[e] <= finished[e] + 1;

  // ---- stimulus -------------------------------------------------------------
  function automatic work_desc_t mk(input int m, input int n, input int k, input int nb);
    work_desc_t d;
    d = '0;
    d.op_class = OPC_GEMM;
    d.dtype    = DT_INT8;
    d.lat_hint = LAT_BALANCED;
    d.pwr_hint = PWR_BALANCED;
    d.dim_m = 16'(m); d.dim_n = 16'(n); d.dim_k = 16'(k);
    d.bytes = 24'(nb);
    return d;
  endfunction

  integer errors = 0, dispatches = 0, completions = 0;
  integer i;
  logic [2:0] first_engine, seen_engine;

  task automatic submit(input work_desc_t d);
    wd = d; wd_valid = 1'b1;
    do @(posedge clk); while (!wd_ready);
    wd_valid = 1'b0;
    @(posedge clk);
  endtask

  // observers
  always_ff @(posedge clk) if (rst_n) begin
    if (disp_valid && disp_accept) begin
      dispatches++;
      seen_engine <= disp_engine;
      if (disp_engine >= NENG) begin errors++; $display("FAIL: engine out of range"); end
    end
    if (comp_valid) completions++;
    if (err_done_unknown) begin errors++; $display("FAIL: crossbar saw an unknown completion"); end
    if (err_bad_engine)   begin errors++; $display("FAIL: crossbar rejected a live decision"); end
    if (err_stale_comp)   begin errors++; $display("FAIL: the MOM saw a stale completion"); end
  end

  initial begin
    for (i = 0; i < NENG; i++) lat[i] = 20;
    wd_valid = 0; wd = '0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // ---- 1. a dispatch reaches the engine the MOM chose --------------------
    submit(mk(4, 4, 4, 48));
    // Ten cycles was enough when five cost engines ran in parallel. The tile
    // now evaluates them on ONE shared engine, two cycles each, so a dispatch
    // lands later. This waits long enough to SEE the dispatch; it does not
    // hide anything, because the in-flight test below still counts every
    // dispatch against every completion.
    repeat (24) @(posedge clk);
    if (!eng_busy[ENG_SIMD]) begin
      errors++; $display("FAIL: 4x4x4 did not reach the SIMD engine (busy=%b)", eng_busy);
    end
    repeat (40) @(posedge clk);
    if (obs_tag_busy != 0) begin
      errors++; $display("FAIL: tag not retired after the engine completed");
    end
    if (finished[ENG_SIMD] != 1) begin
      errors++; $display("FAIL: SIMD engine did not run exactly once");
    end

    submit(mk(8, 8, 8, 192));
    // Ten cycles was enough when five cost engines ran in parallel. The tile
    // now evaluates them on ONE shared engine, two cycles each, so a dispatch
    // lands later. This waits long enough to SEE the dispatch; it does not
    // hide anything, because the in-flight test below still counts every
    // dispatch against every completion.
    repeat (24) @(posedge clk);
    if (!eng_busy[ENG_TPU]) begin
      errors++; $display("FAIL: 8x8x8 did not reach the TPU engine (busy=%b)", eng_busy);
    end
    repeat (40) @(posedge clk);

    // ---- 2. many in flight: every one completes exactly once ---------------
    for (i = 0; i < NENG; i++) lat[i] = 15 + 7 * i;
    for (i = 0; i < 40; i++) begin
      submit(mk(4 + (i % 3) * 4, 4, 4 + (i % 2) * 4, 48 + i));
    end
    repeat (900) @(posedge clk);
    if (obs_tag_busy != 0) begin
      errors++; $display("FAIL: %0d tags still outstanding", $countones(obs_tag_busy));
    end
    if (dispatches != completions) begin
      errors++; $display("FAIL: %0d dispatched but %0d completed", dispatches, completions);
    end
    $display("in flight test: %0d dispatched, %0d completed, per-engine runs %0d %0d %0d %0d %0d",
             dispatches, completions, finished[0], finished[1],
             finished[2], finished[3], finished[4]);

    // ---- 3. the calibration loop closes with no host -----------------------
    // The TPU model is far slower than the cost model predicts. Nothing in
    // this test writes COMP: the engine's own completion is the feedback.
    lat[ENG_TPU] = 900;
    first_engine = 3'd7;
    for (i = 0; i < 60; i++) begin
      submit(mk(8, 8, 8, 192));
      repeat (4) @(posedge clk);
      if (first_engine == 3'd7) first_engine = seen_engine;
      if (seen_engine != first_engine) begin
        $display("calibration moved the decision after %0d dispatches: engine %0d -> %0d",
                 i, first_engine, seen_engine);
        break;
      end
      wait (obs_tag_busy == 0);
      repeat (5) @(posedge clk);
    end
    if (first_engine != ENG_TPU) begin
      errors++; $display("FAIL: 8x8x8 did not start on the TPU (started on %0d)", first_engine);
    end
    if (seen_engine == ENG_TPU) begin
      errors++;
      $display("FAIL: after 60 slow completions the decision never left the TPU");
    end
    $display("calibration updates seen by the MOM: %0d", obs_cal_updates);

    if (errors) begin $display("FAIL tb_mom_system: %0d errors", errors); $fatal(1); end
    $display("PASS tb_mom_system");
    $finish;
  end
endmodule
`default_nettype wire
