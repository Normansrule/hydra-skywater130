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
  localparam int N = 4, AW = 8, DEPTH = 256;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic            eng_valid = 0, eng_ready, eng_done;
  logic [127:0]    eng_wd = '0;
  logic [3:0]      eng_tag = '0, eng_done_tag;
  logic            ld_we = 0, ld_refused;
  logic [1:0]      ld_bank = 0;
  logic [AW+1:0]   ld_addr = 0, c_raddr = 0;
  logic [31:0]     ld_data = 0, c_rdata;
  logic [15:0]     jobs_done;
  logic [2:0]      job_status;

  hydra_engine_simd_dma #(.N(N), .AW(AW), .DEPTH(256)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .ld_we(ld_we), .ld_bank(ld_bank), .ld_addr(ld_addr), .ld_data(ld_data), .ld_refused(ld_refused),
    .c_raddr(c_raddr), .c_rdata(c_rdata),
    .jobs_done(jobs_done), .job_status(job_status));

  localparam int MAXW = 1024, MAXR = 512, MAXC = 16;
  logic [31:0] aw [MAXW], bw [MAXW], expv [MAXR];
  int mop [MAXC], mred [MAXC], mk [MAXC], mbase [MAXC];
  int ncases, errors = 0, checked = 0;
  int refused_n = 0;

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
      // no settling delay: done must mean the results are in memory
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

    // ---- audit R3 (2026-10-11): the top of the result bank --------------------
    // The result pointer used to be the operand banks' width (8 bits, 256
    // words) inside a 1024-word bank, and base_c only 8 of its 10 descriptor
    // bits: results meant for the top of the bank wrapped to the bottom.
    // Re-run job 0 with its results ending on the bank's last word.
    begin
      int want0, top;
      logic ok;
      want0 = mred[0] ? 1 : mk[0] * N;
      top   = DEPTH * 4 - want0;
      desc = '0;
      desc[127:124] = mred[0] ? 4'd2 : 4'd1; desc[123:121] = 3'd2;
      desc[116:101] = 16'(mk[0] * N); desc[2:0] = 3'(mop[0]);
      desc[3 +: AW] = AW'(mbase[0]); desc[13 +: AW] = AW'(mbase[0]);
      desc[23 +: 10] = 10'(top);                // base_c, in words, all ten bits
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = desc; eng_tag = 4'd14; eng_valid = 1; @(negedge clk); eng_valid = 0;
      for (int w = 0; w < 4000 && !done_seen; w++) @(negedge clk);
      for (i = 0; i < want0; i++) begin
        c_raddr = (AW+2)'(top + i);
        @(negedge clk); @(negedge clk);
        if (c_rdata !== expv[i]) begin
          errors++;
          if (errors < 14)
            $display("FAIL top-of-bank job, result %0d at word %0d: memory %08x, model %08x",
                     i, top + i, c_rdata, expv[i]);
        end else checked++;
      end
      // one word further would run past the bank: refused, nothing written
      desc[23 +: 10] = 10'(top + 1);
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = desc; eng_tag = 4'd15; eng_valid = 1; @(negedge clk); eng_valid = 0;
      ok = 0;
      for (int w = 0; w < 200; w++) begin @(negedge clk); if (done_seen) begin ok = 1; break; end end
      if (!ok || job_status !== 3'd4) begin
        errors++; $display("FAIL: a job running past the result bank was not refused (done %0d status %0d)", ok, job_status);
      end
      repeat (4) @(negedge clk);
      if (!eng_ready) begin errors++; $display("FAIL: engine not free after a refusal"); end
      // a descriptor the core refuses (INT8 is not the vector unit's type):
      // the engine must report it and be free again, not wait for ever
      desc[23 +: 10] = 10'd0; desc[123:121] = 3'd0;
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = desc; eng_tag = 4'd13; eng_valid = 1; @(negedge clk); eng_valid = 0;
      ok = 0;
      for (int w = 0; w < 200; w++) begin @(negedge clk); if (done_seen) begin ok = 1; break; end end
      if (!ok || job_status !== 3'd2) begin
        errors++; $display("FAIL: a wrong-type descriptor was not refused (done %0d status %0d)", ok, job_status);
      end
      ok = 0;
      for (int w = 0; w < 50; w++) begin @(negedge clk); if (eng_ready) begin ok = 1; break; end end
      if (!ok) begin errors++; $display("FAIL: the engine never became ready after refusing a descriptor"); end
      ncases += 2;                              // the top-of-bank job and the type refusal
    end

    // ---- the host may not write a bank the engine owns (audit R8) ----------
    // An ELEMENT ADD over GO groups while the host writes junk into A, B and
    // C on every cycle, aimed at the job's operands and results. Results must
    // be exact and operands unchanged.
    begin
      localparam int GO = 64, BO = 128, CO = 512;
      int hammer, bad;
      for (i = 0; i < GO * N; i++) begin
        load(2'd0, BO * N + i, 32'd1); load(2'd1, BO * N + i, 32'd2);
      end
      desc = '0;
      desc[127:124] = 4'd1; desc[123:121] = 3'd2;
      desc[116:101] = 16'(GO * N); desc[2:0] = 3'd0;      // ADD
      desc[3 +: AW] = AW'(BO); desc[13 +: AW] = AW'(BO); desc[23 +: 10] = 10'(CO);
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = desc; eng_tag = 4'd11; eng_valid = 1;
      @(negedge clk); eng_valid = 0;
      hammer = 0; refused_n = 0;
      // stop on the cycle the completion is reported: from then on the host owns the banks again
      while (!done_seen && !eng_done && hammer < 8000) begin
        ld_we = 1; ld_bank = 2'(hammer % 3);
        ld_addr = (hammer % 3 == 2) ? (AW+2)'(CO + (hammer * 5) % (GO * N))
                                    : (AW+2)'(BO * N + (hammer * 7) % (GO * N));
        ld_data = 32'h7F7F7F7F;
        @(negedge clk);
        if (ld_refused) refused_n++;
        hammer++;
      end
      ld_we = 0;
      @(negedge clk); if (ld_refused) refused_n++;
      if (!done_seen) begin errors++; $display("FAIL R8: the job never completed under host writes"); end
      bad = 0;
      for (i = 0; i < GO * N; i++) if (dut.u_c.mem[CO + i] !== 32'd3) bad++;
      if (bad) begin errors++; $display("FAIL R8: %0d of %0d results corrupted by host writes during the job", bad, GO * N); end
      bad = 0;
      for (i = 0; i < GO; i++) begin
        if (dut.g_lane_bank[0].u_a.mem[BO + i] !== 32'd1 || dut.g_lane_bank[3].u_a.mem[BO + i] !== 32'd1) bad++;
        if (dut.g_lane_bank[0].u_b.mem[BO + i] !== 32'd2 || dut.g_lane_bank[3].u_b.mem[BO + i] !== 32'd2) bad++;
      end
      if (bad) begin errors++; $display("FAIL R8: %0d operand entries overwritten while the engine owned them", bad); end
      if (refused_n != hammer) begin
        errors++; $display("FAIL R8: %0d of %0d host writes during the job were reported refused", refused_n, hammer);
      end
      $display("R8: %0d host writes during a %0d-group job; results and operands intact", hammer, GO);
      ncases += 1;
    end

    if (jobs_done !== 16'(ncases + 1)) begin
      errors++; $display("FAIL: %0d jobs done, expected %0d", jobs_done, ncases + 1);
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
