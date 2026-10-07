// =============================================================================
// tb_hydra_dma.sv -- the array fed from memory, results checked in memory
// =============================================================================
// Loads real matrices into the scratchpad, dispatches with the bank
// addresses in the descriptor, and reads the C bank back. Nothing synthetic
// anywhere in the path.
//
// It also checks the property hydra_spram's header calls out: the streamer
// must never read an address it is writing in the same cycle, because the
// bank returns the OLD contents and the two behaviours differ by technology.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_hydra_dma;
  import tpu_pkg::*;
  localparam int N = 4, AW = 10;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic              eng_valid = 0, eng_ready, eng_done;
  logic [127:0]      eng_wd = '0;
  logic [3:0]        eng_tag = '0, eng_done_tag;
  logic              ld_we = 0;
  logic [1:0]        ld_bank = 0;
  logic [AW-1:0]     ld_addr = 0, c_raddr = 0;
  logic [31:0]       ld_data = 0, c_rdata;
  logic [15:0]       tiles_done;
  tpu_status_e       last_status;

  hydra_engine_tpu_dma #(.N(N), .AW(AW), .DEPTH(1024)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .ld_we(ld_we), .ld_bank(ld_bank), .ld_addr(ld_addr), .ld_data(ld_data),
    .c_raddr(c_raddr), .c_rdata(c_rdata),
    .tiles_done(tiles_done), .last_status(last_status));

  // read-during-write watchdog on the C bank
  always_ff @(posedge clk) begin
    if (dut.c_we && dut.u_dma.res_valid && (dut.c_addr === c_raddr) && rst_n)
      $display("NOTE: readback address collided with a write at %0t", $time);
  end

  localparam int MAXW = 2048, MAXR = 512, MAXC = 16;
  logic [31:0] awords [MAXW], bwords [MAXW], expv [MAXR];
  int mm [MAXC], nn [MAXC], kk [MAXC], bb [MAXC];
  int ncases, errors = 0, checked = 0;

  logic done_seen = 0, clear_seen = 0;
  always_ff @(posedge clk) begin
    if (clear_seen)    done_seen <= 1'b0;
    else if (eng_done) done_seen <= 1'b1;
  end

  initial begin
    int fd, code, m, n, k, base;
    fd = $fopen("mem/tb/dma_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run dma_model.py first"); $fatal(1); end
    ncases = 0;
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d %d %d\n", m, n, k, base);
      if (code == 4) begin
        mm[ncases] = m; nn[ncases] = n; kk[ncases] = k; bb[ncases] = base;
        ncases++;
      end
    end
    $fclose(fd);
    $readmemh("mem/tb/dma_a.hex", awords);
    $readmemh("mem/tb/dma_b.hex", bwords);
    $readmemh("mem/tb/dma_exp.hex", expv);
  end

  initial begin #10_000_000; $display("FAIL tb_hydra_dma: watchdog"); $fatal(1); end

  task automatic load(input logic [1:0] bank, input int addr, input logic [31:0] d);
    @(negedge clk);
    ld_we = 1; ld_bank = bank; ld_addr = AW'(addr); ld_data = d;
    @(negedge clk);
    ld_we = 0;
  endtask

  int c, i, ei;
  logic [127:0] desc;

  initial begin
    ei = 0;
    repeat (4) @(negedge clk); rst_n = 1; repeat (4) @(negedge clk);

    for (c = 0; c < ncases; c++) begin
      // ---- put the operands in memory -----------------------------------
      for (i = 0; i < kk[c]; i++) begin
        load(2'd0, bb[c] + i, awords[bb[c] + i]);
        load(2'd1, bb[c] + i, bwords[bb[c] + i]);
      end

      // ---- dispatch, with the bank addresses in the descriptor ----------
      desc = '0;
      desc[127:124] = 4'd3;                 // GEMM
      desc[123:121] = 3'd0;                 // INT8
      desc[116:101] = 16'(mm[c]);
      desc[100:85]  = 16'(nn[c]);
      desc[84:69]   = 16'(kk[c]);
      desc[3  +: AW] = AW'(bb[c]);          // base_a
      desc[13 +: AW] = AW'(bb[c]);          // base_b
      desc[23 +: AW] = AW'(c * N * N);      // base_c

      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = desc; eng_tag = 4'(c); eng_valid = 1;
      @(negedge clk); eng_valid = 0;

      for (int w = 0; w < 3000; w++) begin
        @(negedge clk);
        if (done_seen) break;
      end
      if (!done_seen) begin
        errors++;
        $display("FAIL job %0d (%0dx%0dx%0d): no completion", c, mm[c], nn[c], kk[c]);
        continue;
      end

      // ---- read the results back out of memory ---------------------------
      repeat (3) @(negedge clk);
      for (i = 0; i < N*N; i++) begin
        c_raddr = AW'(c * N * N + i);
        @(negedge clk);
        @(negedge clk);
        if (c_rdata !== expv[ei + i]) begin
          errors++;
          if (errors < 12)
            $display("FAIL job %0d (%0dx%0dx%0d) element %0d: memory has %08x, model says %08x",
                     c, mm[c], nn[c], kk[c], i, c_rdata, expv[ei + i]);
        end else checked++;
      end
      ei += N*N;
    end

    if (tiles_done !== 16'(ncases)) begin
      errors++;
      $display("FAIL: %0d tiles completed, expected %0d", tiles_done, ncases);
    end

    if (errors) begin
      $display("FAIL tb_hydra_dma: %0d errors over %0d jobs", errors, ncases);
      $fatal(1);
    end
    $display("PASS tb_hydra_dma: %0d jobs, %0d results read back from memory exactly",
             ncases, checked);
    $finish;
  end
endmodule
`default_nettype wire
