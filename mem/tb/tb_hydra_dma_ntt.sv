// =============================================================================
// tb_hydra_dma_ntt.sv -- the butterfly engine fed from three memory banks
// =============================================================================
// The streamer's third operand port carries the twiddle factors. Operands
// and twiddles are loaded as the host would, the job is dispatched, and the
// results are read back out of memory and compared with the model. Every
// result is also checked to be a reduced residue: a bank loaded with a value
// >= q produces a wrong answer the engine cannot detect, and this is what
// would catch it.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_hydra_dma_ntt;
  import ntt_pkg::*;
  localparam int N = 4, AW = 8;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic          eng_valid = 0, eng_ready, eng_done;
  logic [127:0]  eng_wd = '0;
  logic [3:0]    eng_tag = '0, eng_done_tag;
  logic          ld_we = 0;
  logic [1:0]    ld_bank = 0;
  logic [AW:0]   ld_addr = 0;
  logic [AW+1:0] c_raddr = 0;
  logic [31:0]   ld_data = 0, c_rdata;
  logic [15:0]   jobs_done;
  ntt_status_e   last_status;

  hydra_engine_ntt_dma #(.N(N), .AW(AW), .DEPTH(256)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .ld_we(ld_we), .ld_bank(ld_bank), .ld_addr(ld_addr), .ld_data(ld_data),
    .c_raddr(c_raddr), .c_rdata(c_rdata),
    .jobs_done(jobs_done), .last_status(last_status));

  localparam int MAXW = 512, MAXR = 512, MAXC = 16;
  logic [31:0] aw [MAXW], bw [MAXW], ww [MAXW], expv [MAXR];
  int mk [MAXC], mbase [MAXC];
  int ncases, errors = 0, checked = 0;

  logic done_seen = 0, clear_seen = 0;
  always_ff @(posedge clk) begin
    if (clear_seen)    done_seen <= 1'b0;
    else if (eng_done) done_seen <= 1'b1;
  end

  initial begin
    int fd, code, k, b;
    fd = $fopen("mem/tb/dma_ntt_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run dma_ntt_model.py first"); $fatal(1); end
    ncases = 0;
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d\n", k, b);
      if (code == 2) begin mk[ncases] = k; mbase[ncases] = b; ncases++; end
    end
    $fclose(fd);
    $readmemh("mem/tb/dma_ntt_a.hex", aw);
    $readmemh("mem/tb/dma_ntt_b.hex", bw);
    $readmemh("mem/tb/dma_ntt_w.hex", ww);
    $readmemh("mem/tb/dma_ntt_exp.hex", expv);
  end

  initial begin #20_000_000; $display("FAIL tb_hydra_dma_ntt: watchdog"); $fatal(1); end

  task automatic load(input logic [1:0] bank, input int addr, input logic [31:0] d);
    @(negedge clk);
    ld_we = 1; ld_bank = bank; ld_addr = (AW+1)'(addr); ld_data = d;
    @(negedge clk);
    ld_we = 0;
  endtask

  int c, i, ei, cbase, want;
  logic [127:0] desc;

  initial begin
    ei = 0; cbase = 0;
    repeat (4) @(negedge clk); rst_n = 1; repeat (4) @(negedge clk);

    for (c = 0; c < ncases; c++) begin
      for (i = 0; i < mk[c] * 2; i++) begin           // two words per group
        load(2'd0, mbase[c]*2 + i, aw[mbase[c]*2 + i]);
        load(2'd1, mbase[c]*2 + i, bw[mbase[c]*2 + i]);
        load(2'd2, mbase[c]*2 + i, ww[mbase[c]*2 + i]);
      end

      desc = '0;
      desc[127:124] = 4'd6;                           // NTT
      desc[123:121] = 3'd5;                           // POLY_Q
      desc[116:101] = 16'(mk[c] * N);                 // pairs
      desc[3  +: AW] = AW'(mbase[c]);
      desc[13 +: AW] = AW'(mbase[c]);
      desc[23 +: AW] = AW'(cbase);

      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = desc; eng_tag = 4'(c); eng_valid = 1;
      @(negedge clk); eng_valid = 0;

      for (int w = 0; w < 4000; w++) begin
        @(negedge clk);
        if (done_seen) break;
      end
      if (!done_seen) begin
        errors++; $display("FAIL job %0d (k %0d): no completion", c, mk[c]);
        continue;
      end

      want = mk[c] * N;
      repeat (8) @(negedge clk);
      for (i = 0; i < want; i++) begin
        c_raddr = (AW+2)'(cbase + i);
        @(negedge clk); @(negedge clk);
        if (c_rdata !== expv[ei + i]) begin
          errors++;
          if (errors < 10)
            $display("FAIL job %0d butterfly %0d: memory %08x, model %08x",
                     c, i, c_rdata, expv[ei + i]);
        end else checked++;
        if (c_rdata[15:0] >= 16'(Q) || c_rdata[31:16] >= 16'(Q)) begin
          errors++;
          $display("FAIL job %0d butterfly %0d: not a reduced residue (%08x)",
                   c, i, c_rdata);
        end
      end
      ei    += want;
      cbase += want;
    end

    if (jobs_done !== 16'(ncases)) begin
      errors++; $display("FAIL: %0d jobs done, expected %0d", jobs_done, ncases);
    end
    if (errors) begin
      $display("FAIL tb_hydra_dma_ntt: %0d errors over %0d jobs", errors, ncases);
      $fatal(1);
    end
    $display("PASS tb_hydra_dma_ntt: %0d jobs, %0d butterflies read back from memory exactly",
             ncases, checked);
    $finish;
  end
endmodule
`default_nettype wire
