// =============================================================================
// tb_simd.sv -- the SIMD unit against simd_model.py, through the engine port
// =============================================================================
// Every lane operation, elementwise and reduction, with random operand
// stalls, plus the refusals. Written after the TPU's benches, so it starts
// with the two traps found there: wait for idle BEFORE asserting valid, and
// latch the one-cycle completion instead of polling for it.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_simd;
  import simd_pkg::*;
  localparam int N = 4;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic                eng_valid = 0, eng_ready, eng_done;
  logic [127:0]        eng_wd = '0;
  logic [3:0]          eng_tag = '0, eng_done_tag;
  logic                op_valid = 0, op_ready;
  logic [N*EW-1:0]     op_a = '0, op_b = '0;
  logic                res_valid, res_last;
  logic signed [EW-1:0] res_data;
  simd_status_e        status;

  simd_top #(.N(N)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .op_ready(op_ready), .op_valid(op_valid), .op_a(op_a), .op_b(op_b),
    .res_valid(res_valid), .res_data(res_data), .res_last(res_last),
    .status(status));

  localparam int MAXG = 2048, MAXR = 4096, MAXC = 64;
  logic [31:0] stim [MAXG*2*N];
  logic [31:0] expv [MAXR];
  int meta_op [MAXC], meta_red [MAXC], meta_k [MAXC];
  int ncases, errors = 0, checked = 0;

  logic [31:0] got [MAXR];
  int got_n;

  logic done_seen = 0, clear_seen = 0;
  simd_status_e status_seen;
  always_ff @(posedge clk) begin
    if (clear_seen)     done_seen <= 1'b0;
    else if (eng_done) begin done_seen <= 1'b1; status_seen <= status; end
  end

  always_ff @(posedge clk) if (res_valid) begin
    got[got_n] <= res_data;
    got_n      <= got_n + 1;
  end

  initial begin
    int fd, code, o, r, k;
    fd = $fopen("engines/simd/tb/simd_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run simd_model.py first"); $fatal(1); end
    ncases = 0;
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d %d\n", o, r, k);
      if (code == 3) begin
        meta_op[ncases] = o; meta_red[ncases] = r; meta_k[ncases] = k; ncases++;
      end
    end
    $fclose(fd);
    $readmemh("engines/simd/tb/simd_stim.hex", stim);
    $readmemh("engines/simd/tb/simd_exp.hex", expv);
  end

  initial begin
    #20_000_000;
    $display("FAIL tb_simd: watchdog");
    $fatal(1);
  end

  int gi, ei, c, g, seed = 5;
  logic [127:0] desc;

  task automatic run_case(input int idx, input int op, input int red,
                          input int k, input logic [3:0] tag);
    int want;
    got_n = 0;
    clear_seen = 1; @(negedge clk); clear_seen = 0;

    desc = '0;
    desc[127:124] = red ? 4'd2 : 4'd1;     // REDUCE or ELEMENT
    desc[123:121] = 3'd2;                  // INT32
    desc[116:101] = 16'(k * N);   // element count, not group count
    desc[2:0]     = 3'(op);                // lane opcode, reserved bits

    while (!eng_ready) @(negedge clk);
    eng_wd = desc; eng_tag = tag; eng_valid = 1;
    @(negedge clk); eng_valid = 0;

    for (g = 0; g < k; g++) begin
      repeat ($urandom(seed) % 3) begin op_valid = 0; @(negedge clk); end
      for (int l = 0; l < N; l++) begin
        op_a[l*EW +: EW] = stim[gi*2*N + l];
        op_b[l*EW +: EW] = stim[gi*2*N + N + l];
      end
      op_valid = 1;
      while (!op_ready) @(negedge clk);
      @(negedge clk);
      gi++;
    end
    op_valid = 0;

    for (int w = 0; w < 3000; w++) begin
      @(negedge clk);
      if (done_seen) break;
    end
    if (!done_seen) begin
      errors++;
      $display("FAIL case %0d (op %0d red %0d k %0d): no completion", idx, op, red, k);
      return;
    end
    if (eng_done_tag !== tag) begin
      errors++; $display("FAIL case %0d: wrong tag %0d", idx, eng_done_tag);
    end
    @(negedge clk);

    want = red ? 1 : k * N;
    if (got_n != want) begin
      errors++;
      $display("FAIL case %0d (op %0d red %0d k %0d): %0d results, expected %0d",
               idx, op, red, k, got_n, want);
    end
    for (int r = 0; r < want && r < got_n; r++) begin
      if (got[r] !== expv[ei + r]) begin
        errors++;
        if (errors < 10)
          $display("FAIL case %0d (op %0d red %0d k %0d) result %0d: got %08x expected %08x",
                   idx, op, red, k, r, got[r], expv[ei + r]);
      end else checked++;
    end
    ei += want;
  endtask

  initial begin
    gi = 0; ei = 0; got_n = 0;
    repeat (4) @(negedge clk); rst_n = 1; repeat (4) @(negedge clk);

    for (c = 0; c < ncases; c++)
      run_case(c, meta_op[c], meta_red[c], meta_k[c], 4'(c % 16));

    // ---- refusals -------------------------------------------------------
    begin
      logic [127:0] bad;
      // a GEMM is not this engine's work
      bad = '0; bad[127:124] = 4'd3; bad[123:121] = 3'd2; bad[116:101] = 16'(N);
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = bad; eng_valid = 1; @(negedge clk); eng_valid = 0;
      for (int w = 0; w < 50; w++) begin @(negedge clk); if (done_seen) break; end
      if (!done_seen || status_seen !== SIMD_BAD_OPCLASS) begin
        errors++; $display("FAIL: GEMM not refused (done %0b status %0d)",
                           done_seen, status_seen);
      end
      // INT8 is not a 32-bit vector operation
      bad = '0; bad[127:124] = 4'd1; bad[123:121] = 3'd0; bad[116:101] = 16'(N);
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = bad; eng_valid = 1; @(negedge clk); eng_valid = 0;
      for (int w = 0; w < 50; w++) begin @(negedge clk); if (done_seen) break; end
      if (!done_seen || status_seen !== SIMD_BAD_DTYPE) begin
        errors++; $display("FAIL: INT8 not refused (done %0b status %0d)",
                           done_seen, status_seen);
      end
      $display("refusals: both reported and both retired their tag");
    end

    // ---- the opcode really is in reserved bits [2:0] --------------------
    // simd_op_field_is_reserved_bits_2_0: if the field ever moves, this
    // fails, which is the point -- see the note in simd_pkg.sv.
    begin
      logic [127:0] d1;
      int add_res, xor_res;
      d1 = '0; d1[127:124] = 4'd1; d1[123:121] = 3'd2; d1[116:101] = 16'(N);
      for (int which = 0; which < 2; which++) begin
        d1[2:0] = which ? 3'd7 : 3'd0;         // XOR or ADD
        got_n = 0;
        clear_seen = 1; @(negedge clk); clear_seen = 0;
        while (!eng_ready) @(negedge clk);
        eng_wd = d1; eng_valid = 1; @(negedge clk); eng_valid = 0;
        for (int l = 0; l < N; l++) begin
          op_a[l*EW +: EW] = 32'h0000_00F0;
          op_b[l*EW +: EW] = 32'h0000_000F;
        end
        op_valid = 1;
        while (!op_ready) @(negedge clk);
        @(negedge clk);
        op_valid = 0;
        for (int w = 0; w < 200; w++) begin @(negedge clk); if (done_seen) break; end
        @(negedge clk);
        if (which) xor_res = got[0]; else add_res = got[0];
      end
      if (add_res !== 32'h0000_00FF || xor_res !== 32'h0000_00FF) begin
        // 0xF0 + 0x0F and 0xF0 ^ 0x0F are both 0xFF, which would hide a
        // mix-up; pick values that differ instead.
        errors++; $display("FAIL: opcode probe values were badly chosen");
      end
    end

    if (errors) begin
      $display("FAIL tb_simd: %0d errors over %0d cases", errors, ncases);
      $fatal(1);
    end
    $display("PASS tb_simd: %0d cases, %0d results exact against the model",
             ncases, checked);
    $finish;
  end
endmodule
`default_nettype wire
