// =============================================================================
// tb_hydra_dma_simd.sv -- the vector unit fed from memory
// =============================================================================
// The same streamer that feeds the array, with wider banks and a
// per-job result count. Loads operands as the host would (four words per
// group), dispatches, reads the results back out of the C bank.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_hydra_dma_simd;
  import simd_pkg::*;
  localparam int N = 4, AW = 8;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic            eng_valid = 0, eng_ready, eng_done;
  logic [127:0]    eng_wd = '0;
  logic [3:0]      eng_tag = '0, eng_done_tag;
  logic            ld_we = 0;
  logic [1:0]      ld_bank = 0;
  logic [AW+1:0]   ld_addr = 0, c_raddr = 0;
  logic [31:0]     ld_data = 0, c_rdata;
  logic [15:0]     jobs_done;
  simd_status_e    last_status;

  hydra_engine_simd_dma #(.N(N), .AW(AW), .DEPTH(256)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .ld_we(ld_we), .ld_bank(ld_bank), .ld_addr(ld_addr), .ld_data(ld_data),
    .c_raddr(c_raddr), .c_rdata(c_rdata),
    .jobs_done(jobs_done), .last_status(last_status));

  localparam int MAXW = 1024, MAXR = 512, MAXC = 16;
  logic [31:0] aw [MAXW], bw [MAXW], expv [MAXR];
  int mop [MAXC], mred [MAXC], mk [MAXC], mbase [MAXC];
  int ncases, errors = 0, checked = 0;

  logic done_seen = 0, clear_seen = 0;
  always_ff @(posedge clk) begin
    if (clear_seen)    done_seen <= 1'b0;
    else if (eng_done) done_seen <= 1'b1;
  end

  initial begin
    int fd, code, o, r, k, b;
    fd = $fopen("mem/tb/dma_simd_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run dma_simd_model.py first"); $fatal(1); end
    ncases = 0;
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d %d %d\n", o, r, k, b);
      if (code == 4) begin
        mop[ncases]=o; mred[ncases]=r; mk[ncases]=k; mbase[ncases]=b; ncases++;
      end
    end
    $fclose(fd);
    $readmemh("mem/tb/dma_simd_a.hex", aw);
    $readmemh("mem/tb/dma_simd_b.hex", bw);
    $readmemh("mem/tb/dma_simd_exp.hex", expv);
  end

  initial begin #20_000_000; $display("FAIL tb_hydra_dma_simd: watchdog"); $fatal(1); end

  task automatic load(input logic [1:0] bank, input int addr, input logic [31:0] d);
    @(negedge clk);
    ld_we = 1; ld_bank = bank; ld_addr = (AW+2)'(addr); ld_data = d;
    @(negedge clk);
    ld_we = 0;
  endtask

  int c, i, ei, want, cbase;
  logic [127:0] desc;

  initial begin
    ei = 0; cbase = 0;
    repeat (4) @(negedge clk); rst_n = 1; repeat (4) @(negedge clk);

    for (c = 0; c < ncases; c++) begin
      // four host words per group, lane order low to high
      for (i = 0; i < mk[c] * N; i++) begin
        load(2'd0, mbase[c]*N + i, aw[mbase[c]*N + i]);
        load(2'd1, mbase[c]*N + i, bw[mbase[c]*N + i]);
      end

      desc = '0;
      desc[127:124] = mred[c] ? 4'd2 : 4'd1;    // REDUCE or ELEMENT
      desc[123:121] = 3'd2;                     // INT32
      desc[116:101] = 16'(mk[c] * N);           // element count
      desc[2:0]     = 3'(mop[c]);               // lane opcode
      desc[3  +: AW] = AW'(mbase[c]);           // base_a, in GROUPS
      desc[13 +: AW] = AW'(mbase[c]);           // base_b
      desc[23 +: AW] = AW'(cbase);              // base_c, in words

      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = desc; eng_tag = 4'(c); eng_valid = 1;
      @(negedge clk); eng_valid = 0;

      for (int w = 0; w < 4000; w++) begin
        @(negedge clk);
        if (done_seen) break;
      end
      if (!done_seen) begin
        errors++;
        $display("FAIL job %0d (op %0d red %0d k %0d): no completion",
                 c, mop[c], mred[c], mk[c]);
        continue;
      end

      want = mred[c] ? 1 : mk[c] * N;
      repeat (3) @(negedge clk);
      for (i = 0; i < want; i++) begin
        c_raddr = (AW+2)'(cbase + i);
        @(negedge clk); @(negedge clk);
        if (c_rdata !== expv[ei + i]) begin
          errors++;
          if (errors < 10)
            $display("FAIL job %0d (op %0d red %0d k %0d) result %0d: memory %08x, model %08x",
                     c, mop[c], mred[c], mk[c], i, c_rdata, expv[ei + i]);
        end else checked++;
      end
      ei    += want;
      cbase += want;
    end

    if (jobs_done !== 16'(ncases)) begin
      errors++; $display("FAIL: %0d jobs done, expected %0d", jobs_done, ncases);
    end
    if (errors) begin
      $display("FAIL tb_hydra_dma_simd: %0d errors over %0d jobs", errors, ncases);
      $fatal(1);
    end
    $display("PASS tb_hydra_dma_simd: %0d jobs, %0d results read back from memory exactly",
             ncases, checked);
    $finish;
  end
endmodule
`default_nettype wire
