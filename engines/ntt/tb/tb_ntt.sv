// =============================================================================
// tb_ntt.sv -- the butterfly engine against ntt_model.py
// =============================================================================
// Field corners first (0, 1, q-1 in every position), then random, through
// the engine port with stalls and refusals. The model asserts the Barrett
// bound on every vector it generates, so a reduction that needs two
// subtracts fails in Python before the hardware is even run.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_ntt;
  import ntt_pkg::*;
  localparam int N = 4;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic              eng_valid = 0, eng_ready, eng_done;
  logic [127:0]      eng_wd = '0;
  logic [3:0]        eng_tag = '0, eng_done_tag;
  logic              op_valid = 0, op_ready;
  logic [N*QW-1:0]   op_a = '0, op_b = '0, op_w = '0;
  logic              res_valid;
  logic [N*QW-1:0]   res_y0, res_y1;
  ntt_status_e       status;

  ntt_top #(.N(N)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .op_ready(op_ready), .op_valid(op_valid),
    .op_a(op_a), .op_b(op_b), .op_w(op_w),
    .res_valid(res_valid), .res_y0(res_y0), .res_y1(res_y1), .status(status));

  localparam int MAXG = 512, MAXB = 4096, MAXC = 64;
  // 32 bits per value, whatever q is: a 23-bit residue does not fit in 16.
  logic [31:0] stim [MAXG*3*N];
  logic [31:0] expv [MAXB*2];
  int meta_k [MAXC];
  int ncases, errors = 0, checked = 0;

  logic [31:0] got0 [MAXB], got1 [MAXB];
  int got_n;

  logic done_seen = 0, clear_seen = 0;
  ntt_status_e status_seen;
  always_ff @(posedge clk) begin
    if (clear_seen)    done_seen <= 1'b0;
    else if (eng_done) begin done_seen <= 1'b1; status_seen <= status; end
  end

  always_ff @(posedge clk) if (res_valid) begin
    for (int l = 0; l < N; l++) begin
      got0[got_n + l] <= res_y0[l*QW +: QW];
      got1[got_n + l] <= res_y1[l*QW +: QW];
    end
    got_n <= got_n + N;
  end

  initial begin
    int fd, code, k;
    fd = $fopen("engines/ntt/tb/ntt_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run ntt_model.py first"); $fatal(1); end
    ncases = 0;
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d\n", k);
      if (code == 1) begin meta_k[ncases] = k; ncases++; end
    end
    $fclose(fd);
    $readmemh("engines/ntt/tb/ntt_stim.hex", stim);
    $readmemh("engines/ntt/tb/ntt_exp.hex", expv);
  end

  initial begin
    #20_000_000; $display("FAIL tb_ntt: watchdog"); $fatal(1);
  end

  int gi, ei, c, g, seed = 11;
  logic [127:0] desc;

  task automatic run_case(input int idx, input int k, input logic [3:0] tag);
    got_n = 0;
    clear_seen = 1; @(negedge clk); clear_seen = 0;

    desc = '0;
    desc[127:124] = 4'd6;              // NTT
    desc[123:121] = 3'd5;              // POLY_Q
    desc[116:101] = 16'(k * N);        // pairs, a multiple of the lane count

    while (!eng_ready) @(negedge clk);
    eng_wd = desc; eng_tag = tag; eng_valid = 1;
    @(negedge clk); eng_valid = 0;

    for (g = 0; g < k; g++) begin
      repeat ($urandom(seed) % 3) begin op_valid = 0; @(negedge clk); end
      for (int l = 0; l < N; l++) begin
        op_a[l*QW +: QW] = stim[gi*3*N + l][QW-1:0];
        op_b[l*QW +: QW] = stim[gi*3*N + N + l][QW-1:0];
        op_w[l*QW +: QW] = stim[gi*3*N + 2*N + l][QW-1:0];
      end
      op_valid = 1;
      while (!op_ready) @(negedge clk);
      @(negedge clk);
      gi++;
    end
    op_valid = 0;

    for (int w = 0; w < 500; w++) begin
      @(negedge clk);
      if (done_seen) break;
    end
    if (!done_seen) begin
      errors++; $display("FAIL case %0d (k %0d): no completion", idx, k); return;
    end
    if (eng_done_tag !== tag) begin
      errors++; $display("FAIL case %0d: wrong tag", idx);
    end
    @(negedge clk);

    if (got_n != k * N) begin
      errors++;
      $display("FAIL case %0d: %0d butterflies, expected %0d", idx, got_n, k*N);
    end
    for (int r = 0; r < k*N && r < got_n; r++) begin
      if (got0[r] !== 32'(expv[(ei + r)*2]) || got1[r] !== 32'(expv[(ei + r)*2 + 1])) begin
        errors++;
        if (errors < 10)
          $display("FAIL case %0d butterfly %0d: got (%04x,%04x) expected (%04x,%04x)",
                   idx, r, got0[r], got1[r], expv[(ei+r)*2], expv[(ei+r)*2+1]);
      end else checked++;
      // every output must be a reduced residue, always
      if (got0[r] >= 32'(Q) || got1[r] >= 32'(Q)) begin
        errors++;
        $display("FAIL case %0d butterfly %0d: result not reduced (%04x,%04x)",
                 idx, r, got0[r], got1[r]);
      end
    end
    ei += k * N;
  endtask

  initial begin
    gi = 0; ei = 0; got_n = 0;
    repeat (4) @(negedge clk); rst_n = 1; repeat (4) @(negedge clk);

    for (c = 0; c < ncases; c++) run_case(c, meta_k[c], 4'(c % 16));

    begin
      logic [127:0] bad;
      // a GEMM is not a transform
      bad = '0; bad[127:124] = 4'd3; bad[123:121] = 3'd5; bad[116:101] = 16'(N);
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = bad; eng_valid = 1; @(negedge clk); eng_valid = 0;
      for (int w = 0; w < 50; w++) begin @(negedge clk); if (done_seen) break; end
      if (!done_seen || status_seen !== NTT_BAD_OPCLASS) begin
        errors++; $display("FAIL: GEMM not refused (%0b %0d)", done_seen, status_seen);
      end
      // a pair count that is not a whole number of groups
      bad = '0; bad[127:124] = 4'd6; bad[123:121] = 3'd5; bad[116:101] = 16'(N + 1);
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = bad; eng_valid = 1; @(negedge clk); eng_valid = 0;
      for (int w = 0; w < 50; w++) begin @(negedge clk); if (done_seen) break; end
      if (!done_seen || status_seen !== NTT_BAD_DIMS) begin
        errors++; $display("FAIL: partial group not refused (%0b %0d)",
                           done_seen, status_seen);
      end
      $display("refusals: wrong class and partial group both reported");
    end

    if (errors) begin
      $display("FAIL tb_ntt: %0d errors over %0d cases", errors, ncases); $fatal(1);
    end
    $display("PASS tb_ntt: %0d cases, %0d butterflies exact against the model",
             ncases, checked);
    $finish;
  end
endmodule
`default_nettype wire
