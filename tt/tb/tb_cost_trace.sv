// =============================================================================
// tb_cost_trace.sv -- the shared cost engine reaches the SAME DECISIONS
// =============================================================================
// WHY THIS EXISTS
//
// tb_v1_v2_diff proves the PARALLEL build is v1, pin for pin. The tile ships
// the SHARED build, which computes the same costs on one engine over more
// cycles, so it cannot be cycle identical and that bench cannot speak for it.
// Without this bench the shipped configuration would rest on "the tests pass",
// which says the tile works, not that it decides the same things.
//
// The claim being tested is exactly: for the same sequence of descriptors,
// both builds dispatch to the same engines, in the same order, with the same
// refusals. Not the same cycles -- that is the whole point of the change.
//
// HOW
//
// The stimulus is SELF-TIMED: each descriptor waits for wd_ready, and the
// bench waits for the dispatch before submitting the next one. A fixed pin
// sequence would be unfair, because the two builds are ready at different
// times and one of them would silently drop descriptors the other accepted.
//
// Each dispatch prints one line. Two runs, one per build, then a plain diff
// of the two traces: identical means the decisions are identical.
//
//   make cost-mux
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_cost_trace;
  import mom_pkg::*;

  localparam int JOBS = 120;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  work_desc_t  wd;
  logic        wd_valid = 1'b0;
  wire         wd_ready;
  wire         disp_valid;
  wire [2:0]   disp_engine;
  wire [3:0]   disp_tag;
  work_desc_t  disp_wd;
  logic        comp_valid = 1'b0;
  logic [3:0]  comp_tag = '0;
  wire         err_unsupported;
  wire [7:0]   err_tag;

  mom_top #(.NTAG(8), .QMAX(4)) dut (
    .clk(clk), .rst_n(rst_n),
    .wd_valid(wd_valid), .wd_ready(wd_ready), .wd(wd),
    .disp_valid(disp_valid), .disp_accept(1'b1),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(comp_valid), .comp_tag(comp_tag),
    .fence_tag(4'd0), .fence_busy(),
    .csr_wr(1'b0), .csr_priv(1'b0), .csr_engine(3'd0), .csr_data('0),
    .csr_bw_dma_log2(4'd4), .csr_eps_mem(4'd2), .csr_e_shift(4'd3),
    .csr_cal_freeze(1'b0), .csr_cal_reset(1'b0),
    .err_unsupported(err_unsupported), .err_tag(err_tag),
    .err_stale_comp(), .obs_margin(), .obs_cal_updates(), .obs_tag_busy()
  );

  // ---- retire every tag a few cycles after it is dispatched ----------------
  // Without completions the scoreboard fills and the trace stops early, which
  // would compare two short traces and call them equal.
  logic [3:0] pend [16];
  int         pend_n = 0, pend_rd = 0;
  int         age [16];

  always_ff @(posedge clk) begin
    comp_valid <= 1'b0;
    if (disp_valid) begin
      pend[pend_n % 16] <= disp_tag;
      age[pend_n % 16]  <= 0;
      pend_n            <= pend_n + 1;
    end
    if (pend_rd < pend_n) begin
      if (age[pend_rd % 16] > 6) begin
        comp_valid <= 1'b1;
        comp_tag   <= pend[pend_rd % 16];
        pend_rd    <= pend_rd + 1;
      end else begin
        age[pend_rd % 16] <= age[pend_rd % 16] + 1;
      end
    end
  end

  // ---- the trace -----------------------------------------------------------
  int dispatches = 0, refusals = 0;

  always_ff @(posedge clk) begin
    if (rst_n && disp_valid) begin
      $display("D %0d %0d %0d %0d %0d",
               disp_engine, disp_wd.op_class, disp_wd.dtype,
               disp_wd.dim_m, disp_wd.dim_k);
      dispatches <= dispatches + 1;
    end
    if (rst_n && err_unsupported) begin
      $display("U %0d %0d", disp_wd.op_class, disp_wd.dtype);
      refusals <= refusals + 1;
    end
  end

  // ---- stimulus ------------------------------------------------------------
  int seed = 20260925;
  int i;

  task automatic submit(input work_desc_t d);
    wd = d; wd_valid = 1'b1;
    do @(posedge clk); while (!wd_ready);
    wd_valid = 1'b0;
    @(posedge clk);
  endtask

  function automatic work_desc_t rnd_desc(input int n);
    work_desc_t d;
    int r;
    d = '0;
    r          = $random(seed);
    d.op_class = opclass_e'((r >> 3) % 9);
    d.dtype    = dtype_e'((r >> 7) % 6);
    d.lat_hint = lat_hint_e'((r >> 11) % 4);
    d.pwr_hint = pwr_hint_e'((r >> 13) % 4);
    d.dim_m    = 16'(1 + ((r >> 15) % 64));
    d.dim_n    = 16'(1 + ((r >> 19) % 64));
    d.dim_k    = 16'(1 + ((r >> 23) % 64));
    d.bytes    = 24'(((r >> 5) % 4096));
    return d;
  endfunction

  initial begin
    #5_000_000;
    $display("FAIL tb_cost_trace: watchdog");
    $fatal(1);
  end

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    for (i = 0; i < JOBS; i++) begin
      submit(rnd_desc(i));
      // Let the dispatch resolve. Long enough for the shared build's sweep,
      // harmless for the parallel one: the traces are compared by content,
      // not by when the lines were printed.
      repeat (40) @(posedge clk);
    end

    repeat (60) @(posedge clk);
    $display("END %0d dispatches %0d refusals", dispatches, refusals);
    $finish;
  end
endmodule

`default_nettype wire
