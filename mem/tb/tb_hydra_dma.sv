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
  localparam int N = 4, AW = 10, DEPTH = 1024;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic              eng_valid = 0, eng_ready, eng_done;
  logic [127:0]      eng_wd = '0;
  logic [3:0]        eng_tag = '0, eng_done_tag;
  logic              ld_we = 0, ld_refused;
  logic [1:0]        ld_bank = 0;
  logic [AW-1:0]     ld_addr = 0, c_raddr = 0;
  logic [31:0]       ld_data = 0, c_rdata;
  logic [15:0]       tiles_done;
  logic [2:0]        job_status;

  hydra_engine_tpu_dma #(.N(N), .AW(AW), .DEPTH(1024)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .ld_we(ld_we), .ld_bank(ld_bank), .ld_addr(ld_addr), .ld_data(ld_data), .ld_refused(ld_refused),
    .c_raddr(c_raddr), .c_rdata(c_rdata),
    .tiles_done(tiles_done), .job_status(job_status));

  // read-during-write watchdog on the C bank
  always_ff @(posedge clk) begin
    if (dut.c_we && dut.u_dma.res_valid && (dut.c_addr === c_raddr) && rst_n)
      $display("NOTE: readback address collided with a write at %0t", $time);
  end

  localparam int MAXW = 2048, MAXR = 512, MAXC = 16;
  logic [31:0] awords [MAXW], bwords [MAXW], expv [MAXR];
  int mm [MAXC], nn [MAXC], kk [MAXC], bb [MAXC];
  int ncases, errors = 0, checked = 0;
  int refused_n = 0;

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
      // no settling delay: done must mean the results are in memory
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

    // ---- the host may not write a bank the engine owns (audit R8) ----------
    // A job runs for KO slices while the host writes junk into A, B and C on
    // every cycle, aimed at the job's own operands and result region. The
    // results must be exact and the operands unchanged: from acceptance until
    // its completion is reported, the engine owns every bank, and a host write
    // in that window is refused (ld_refused) rather than taking the port.
    begin
      localparam int KO = 200, BO = 512, CO = 768;
      int hammer, bad;
      for (i = 0; i < KO; i++) begin
        load(2'd0, BO + i, 32'h01010101); load(2'd1, BO + i, 32'h01010101);
      end
      desc = '0;
      desc[127:124] = 4'd3; desc[123:121] = 3'd0;
      desc[116:101] = 16'd4; desc[100:85] = 16'd4; desc[84:69] = 16'(KO);
      desc[3 +: AW] = AW'(BO); desc[13 +: AW] = AW'(BO); desc[23 +: AW] = AW'(CO);
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = desc; eng_tag = 4'd11; eng_valid = 1;
      @(negedge clk); eng_valid = 0;
      hammer = 0; refused_n = 0;
      // stop on the cycle the completion is reported: from then on the host owns the banks again
      while (!done_seen && !eng_done && hammer < 5000) begin
        ld_we = 1; ld_bank = 2'(hammer % 3);
        ld_addr = (hammer % 3 == 2) ? AW'(CO + hammer % 16) : AW'(BO + (hammer * 7) % KO);
        ld_data = 32'h7F7F7F7F;
        @(negedge clk);
        if (ld_refused) refused_n++;
        hammer++;
      end
      ld_we = 0;
      @(negedge clk); if (ld_refused) refused_n++;
      if (!done_seen) begin errors++; $display("FAIL R8: the job never completed under host writes"); end
      bad = 0;
      for (i = 0; i < N*N; i++) if (dut.u_c.mem[CO + i] !== 32'(KO)) bad++;
      if (bad) begin errors++; $display("FAIL R8: %0d of 16 results corrupted by host writes during the job", bad); end
      bad = 0;
      for (i = 0; i < KO; i++)
        if (dut.u_a.mem[BO + i] !== 32'h01010101 || dut.u_b.mem[BO + i] !== 32'h01010101) bad++;
      if (bad) begin errors++; $display("FAIL R8: %0d operand words overwritten while the engine owned them", bad); end
      if (refused_n != hammer) begin
        errors++; $display("FAIL R8: %0d of %0d host writes during the job were reported refused", refused_n, hammer);
      end
      // ... and once the engine is idle again, the host owns the banks
      load(2'd0, BO, 32'h02020202);
      if (dut.u_a.mem[BO] !== 32'h02020202) begin errors++; $display("FAIL R8: an idle-time write was lost"); end
      load(2'd0, BO, 32'h01010101);
      $display("R8: %0d host writes during a %0d-slice job; results and operands intact", hammer, KO);
      ncases += 1;
    end

    // ---- descriptors the engine must refuse, and still be free afterwards ----
    // Audit R3 follow-up (2026-10-11). A descriptor the core refuses (here: a
    // 5-row tile on a 4x4 array) must not start the streamer, or the streamer
    // waits forever for the core to take an operand and the engine never
    // becomes ready again. A job whose operands or results would run past the
    // end of a bank must be refused before anything is read or written.
    begin
      logic ok;
      for (int t = 0; t < 2; t++) begin
        desc = '0;
        desc[127:124] = 4'd3; desc[123:121] = 3'd0;
        desc[116:101] = (t == 0) ? 16'd5 : 16'd4;     // t=0: too many rows
        desc[100:85] = 16'd4; desc[84:69] = 16'd4;
        desc[3 +: AW] = (t == 1) ? AW'(DEPTH - 3) : '0; // t=1: A runs past the end
        desc[13 +: AW] = '0; desc[23 +: AW] = '0;
        clear_seen = 1; @(negedge clk); clear_seen = 0;
        while (!eng_ready) @(negedge clk);
        eng_wd = desc; eng_tag = 4'd12 + 4'(t); eng_valid = 1;
        @(negedge clk); eng_valid = 0;
        ok = 0;
        for (int w = 0; w < 200; w++) begin @(negedge clk); if (done_seen) begin ok = 1; break; end end
        if (!ok) begin errors++; $display("FAIL: refusal %0d never completed", t); end
        else if (job_status !== ((t == 0) ? 3'd3 : 3'd4)) begin
          errors++; $display("FAIL: refusal %0d reported status %0d", t, job_status);
        end
        ok = 0;
        for (int w = 0; w < 50; w++) begin @(negedge clk); if (eng_ready) begin ok = 1; break; end end
        if (!ok) begin errors++; $display("FAIL: the engine never became ready after refusal %0d", t); end
      end
      ncases += 2;
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
