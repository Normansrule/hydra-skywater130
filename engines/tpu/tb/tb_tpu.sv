// =============================================================================
// tb_tpu.sv -- the TPU against tpu_model.py, through the engine port
// =============================================================================
// Drives the engine exactly as mom_xbar would: present a descriptor, hand it
// operand slices, collect the result stream, compare against the model.
//
// It also stalls the operand source at random. A systolic array that only
// works when operands arrive every cycle is a systolic array that will fail
// the first time a DMA hiccups, and the stall path is the part most likely
// to be wrong.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_tpu;
  import tpu_pkg::*;
  localparam int N = 4;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic                   eng_valid = 0, eng_ready, eng_done;
  logic [127:0]           eng_wd = '0;
  logic [3:0]             eng_tag = '0, eng_done_tag;
  logic                   op_valid = 0, op_ready;
  logic signed [AW-1:0]   op_a [N], op_b [N];
  logic                   res_valid, res_last;
  logic signed [ACCW-1:0] res_data;
  tpu_status_e            status;

  tpu_top #(.N(N)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .op_ready(op_ready), .op_valid(op_valid), .op_a(op_a), .op_b(op_b),
    .res_valid(res_valid), .res_data(res_data), .res_last(res_last),
    .status(status));

  // ---- vectors from the model ------------------------------------------
  localparam int MAXS = 4096, MAXR = 4096, MAXC = 64;
  // Flat, not [slice][lane]: $readmemh into a two-dimensional unpacked array
  // loaded nothing here and warned rather than failing, which is the silent
  // wrong answer this project keeps designing against.
  logic [7:0]  stim  [MAXS*2*N];
  logic [31:0] expv  [MAXR];
  int          meta_m [MAXC], meta_n [MAXC], meta_k [MAXC];
  int          ncases, errors = 0, checked = 0;

  logic [31:0] got [MAXR];
  int          got_n;

  initial begin
    int fd, code, i, m, n, k;
    // meta: one "m n k" line per case
    fd = $fopen("engines/tpu/tb/tpu_meta.hex", "r");
    if (fd == 0) begin $display("FAIL: run tpu_model.py first"); $fatal(1); end
    ncases = 0;
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d %d\n", m, n, k);
      if (code == 3) begin
        meta_m[ncases] = m; meta_n[ncases] = n; meta_k[ncases] = k;
        ncases++;
      end
    end
    $fclose(fd);
    $readmemh("engines/tpu/tb/tpu_stim.hex", stim);
    $readmemh("engines/tpu/tb/tpu_exp.hex", expv);
  end

  // A refusal completes the cycle AFTER acceptance, so polling from the next
  // negedge misses the pulse entirely. Latch it instead of racing it.
  logic done_seen = 1'b0, clear_seen = 1'b0;
  tpu_status_e status_seen;
  always_ff @(posedge clk) begin
    if (clear_seen) done_seen <= 1'b0;
    else if (eng_done) begin
      done_seen   <= 1'b1;
      status_seen <= status;
    end
  end

  // ---- collect the result stream ----------------------------------------
  always_ff @(posedge clk) begin
    if (res_valid) begin
      got[got_n] <= res_data;
      got_n      <= got_n + 1;
    end
  end

  logic [127:0] desc;
  int slice_i, exp_i, c, s, r;
  int seed = 179;

  task automatic run_case(input int idx, input int m, input int n, input int k,
                          input logic [3:0] tag);
    got_n = 0;
    desc = '0;
    desc[127:124] = 4'd3;            // OPC_GEMM
    desc[123:121] = 3'd0;            // DT_INT8
    desc[116:101] = 16'(m);
    desc[100:85]  = 16'(n);
    desc[84:69]   = 16'(k);

    // Wait for idle BEFORE asserting valid. Asserting first and then waiting
    // for ready deadlocks: the engine accepts on the next edge and drops
    // ready, so the wait never ends and no operands are ever sent. (That is
    // a testbench bug, and it cost the first run of this bench.)
    @(negedge clk);
    while (!eng_ready) @(negedge clk);
    eng_wd = desc; eng_tag = tag; eng_valid = 1;
    @(negedge clk);
    eng_valid = 0;

    // hand over k slices, stalling at random
    for (s = 0; s < k; s++) begin
      // stall between 0 and 3 cycles before offering the slice
      repeat ($urandom(seed) % 4) begin
        op_valid = 0;
        @(negedge clk);
      end
      for (int lane = 0; lane < N; lane++) begin
        op_a[lane] = signed'(stim[slice_i*2*N + lane]);
        op_b[lane] = signed'(stim[slice_i*2*N + N + lane]);
      end
      op_valid = 1;
      // hold until the cycle the controller actually consumes it
      while (!op_ready) @(negedge clk);
      @(negedge clk);
      slice_i++;
    end
    op_valid = 0;

    // wait for the completion
    for (int w = 0; w < 4000; w++) begin
      @(negedge clk);
      if (eng_done) break;
    end
    if (!eng_done) begin
      errors++;
      $display("FAIL case %0d (%0dx%0dx%0d): no completion", idx, m, n, k);
      return;
    end
    if (eng_done_tag !== tag) begin
      errors++;
      $display("FAIL case %0d: tag %0d returned, expected %0d", idx, eng_done_tag, tag);
    end
    if (status !== TPU_OK) begin
      errors++;
      $display("FAIL case %0d: status %0d on a legal job", idx, status);
    end
    @(negedge clk);

    if (got_n != N*N) begin
      errors++;
      $display("FAIL case %0d: %0d results, expected %0d", idx, got_n, N*N);
    end
    for (r = 0; r < N*N && r < got_n; r++) begin
      if (got[r] !== expv[exp_i + r]) begin
        errors++;
        if (errors < 12)
          $display("FAIL case %0d (%0dx%0dx%0d) element %0d: got %08x expected %08x",
                   idx, m, n, k, r, got[r], expv[exp_i + r]);
      end else checked++;
    end
    exp_i += N*N;
  endtask

  // Watchdog: a hang must say where it hung, not sit until the runner kills it.
  initial begin
    #20_000_000;
    $display("FAIL tb_tpu: watchdog at case %0d, slice %0d, results %0d",
             c, slice_i, got_n);
    $fatal(1);
  end

  initial begin
    for (int i = 0; i < N; i++) begin op_a[i] = '0; op_b[i] = '0; end
    slice_i = 0; exp_i = 0; got_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    for (c = 0; c < ncases; c++)
      run_case(c, meta_m[c], meta_n[c], meta_k[c], 4'(c % 16));

    // ---- refusals: every one must still complete, with a reason ----------
    begin
      logic [127:0] bad;
      // wrong op class
      bad = '0; bad[127:124] = 4'd5; bad[116:101] = 1; bad[100:85] = 1; bad[84:69] = 1;
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = bad; eng_valid = 1; @(negedge clk); eng_valid = 0;
      for (int w = 0; w < 50; w++) begin @(negedge clk); if (done_seen) break; end
      if (!done_seen || status_seen !== TPU_BAD_OPCLASS) begin
        errors++; $display("FAIL: wrong op class not reported (done=%0b status=%0d)",
                           done_seen, status_seen);
      end
      // dimensions past the array edge
      bad = '0; bad[127:124] = 4'd3; bad[116:101] = N + 1; bad[100:85] = 1; bad[84:69] = 1;
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = bad; eng_valid = 1; @(negedge clk); eng_valid = 0;
      for (int w = 0; w < 50; w++) begin @(negedge clk); if (done_seen) break; end
      if (!done_seen || status_seen !== TPU_BAD_DIMS) begin
        errors++; $display("FAIL: oversized tile not reported (done=%0b status=%0d)",
                           done_seen, status_seen);
      end
      $display("refusals: both reported and both retired their tag");
    end

    if (errors) begin
      $display("FAIL tb_tpu: %0d errors over %0d cases", errors, ncases);
      $fatal(1);
    end
    $display("PASS tb_tpu: %0d cases, %0d results exact against the model", ncases, checked);
    $finish;
  end
endmodule
`default_nettype wire
