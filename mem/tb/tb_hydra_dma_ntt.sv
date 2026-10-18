// =============================================================================
// tb_hydra_dma_ntt.sv -- the butterfly engine fed from memory, end to end
// =============================================================================
// Host load -> streamer -> butterflies -> serialiser -> C bank -> host read,
// in MEMORY FORMAT v1 (one residue per 32-bit word), at whatever modulus the
// build was made for: scripts/ntt_moduli.sh --bench dma runs all three.
//
// Rewritten for audit R2/R3 (2026-10-11). The old bench ran only at
// q = 12289, where the 16-bit-slot format happened to work, and waited eight
// cycles after done before reading -- slack that would hide a completion
// reported before the last result was written. This one:
//   * reads the results starting the cycle done is seen, with no settling;
//   * checks the edges: residues 0 and q-1, the last legal groups, one group
//     past the end of C and of A (refused, nothing written, engine still
//     free), the longest job the banks hold, all three bases equal, a
//     descriptor the core refuses;
//   * checks the load boundary: a residue >= q, a word with bits above q's
//     width, and an address past the bank are refused and change nothing;
//   * resets in the middle of a job and runs a job correctly afterwards.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_hydra_dma_ntt;
  import ntt_pkg::*;
  localparam int N = 4, AW = 8, DEPTH = 256, RPG = 2 * N;
  localparam int LAW = AW + 3;                     // host word address bits

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic          eng_valid = 0, eng_ready, eng_done;
  logic [127:0]  eng_wd = '0;
  logic [3:0]    eng_tag = '0, eng_done_tag;
  logic          ld_we = 0, ld_refused;
  logic [1:0]    ld_bank = 0;
  logic [LAW-1:0] ld_addr = 0, c_raddr = 0;
  logic [31:0]   ld_data = 0, c_rdata;
  logic [15:0]   jobs_done;
  logic [2:0]    job_status;

  hydra_engine_ntt_dma #(.N(N), .AW(AW), .DEPTH(DEPTH)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .ld_we(ld_we), .ld_bank(ld_bank), .ld_addr(ld_addr), .ld_data(ld_data),
    .ld_refused(ld_refused), .c_raddr(c_raddr), .c_rdata(c_rdata),
    .jobs_done(jobs_done), .job_status(job_status));

  // ---- the model's jobs ------------------------------------------------------
  localparam int MAXJ = 16, MAXD = 8192;
  int jkind [MAXJ], jg [MAXJ], jba [MAXJ], jbb [MAXJ], jbc [MAXJ], jst [MAXJ];
  logic [31:0] dat [MAXD];
  logic [31:0] csnap [2048];
  int njobs = 0, nwords = 0, mq = 0, mdepth = 0;
  int errors = 0, checked = 0, ran = 0;

  initial begin
    int fd, code, k, g, a, b, c, st;
    fd = $fopen("mem/tb/dma_ntt_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run dma_ntt_model.py first"); $fatal(1); end
    code = $fscanf(fd, "%d %d %d\n", mq, mdepth, nwords);
    $fclose(fd);
    fd = $fopen("mem/tb/dma_ntt_jobs.txt", "r");
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d %d %d %d %d\n", k, g, a, b, c, st);
      if (code == 6) begin
        jkind[njobs] = k; jg[njobs] = g; jba[njobs] = a; jbb[njobs] = b;
        jbc[njobs] = c; jst[njobs] = st; njobs++;
      end
    end
    $fclose(fd);
    $readmemh("mem/tb/dma_ntt_data.hex", dat);
  end

  initial begin #200_000_000; $display("FAIL tb_hydra_dma_ntt: watchdog"); $fatal(1); end

  logic done_seen = 0, clear_seen = 0;
  logic [2:0] st_seen;
  always_ff @(posedge clk) begin
    if (clear_seen)    done_seen <= 1'b0;
    else if (eng_done) begin done_seen <= 1'b1; st_seen <= job_status; end
  end

  task automatic load(input logic [1:0] bank, input int addr, input logic [31:0] d);
    @(negedge clk);
    ld_we = 1; ld_bank = bank; ld_addr = LAW'(addr); ld_data = d;
    @(negedge clk);
    ld_we = 0;
  endtask

  // One read per cycle: the address is presented on a falling edge, the bank
  // registers it on the rising edge, and the word is valid at the next fall.
  task automatic read_c(input int addr, output logic [31:0] v);
    c_raddr = LAW'(addr);
    @(negedge clk);
    v = c_rdata;
  endtask

  function automatic logic [127:0] ntt_desc(input int g, input int ba, input int bb, input int bc,
                                            input logic [3:0] opc);
    logic [127:0] d = '0;
    d[127:124] = opc; d[123:121] = 3'd5;            // POLY_Q
    d[116:101] = 16'(g * N);                        // butterfly pairs
    d[3 +: AW] = AW'(ba); d[13 +: AW] = AW'(bb); d[23 +: AW] = AW'(bc);
    return d;
  endfunction

  task automatic dispatch(input logic [127:0] d, input logic [3:0] tag, output logic ok);
    clear_seen = 1; @(negedge clk); clear_seen = 0;
    while (!eng_ready) @(negedge clk);
    eng_wd = d; eng_tag = tag; eng_valid = 1;
    @(negedge clk); eng_valid = 0;
    ok = 0;
    for (int w = 0; w < 20000; w++) begin
      if (done_seen) begin ok = 1; break; end
      @(negedge clk);
    end
  endtask

  int p, j, i;
  logic ok;
  logic [31:0] v;

  initial begin
    repeat (4) @(negedge clk); rst_n = 1; repeat (4) @(negedge clk);
    p = 0;

    // a pattern in C, so anything a job should not write is visible
    for (i = 0; i < DEPTH * RPG; i++) load(2'd3, i, 32'hA5A5_0000 | 32'(i));

    for (j = 0; j < njobs; j++) begin
      if (jkind[j] == 0) begin
        // ---- operands: one residue per word, group*4 + lane ---------------
        for (i = 0; i < jg[j] * N; i++) begin
          load(2'd0, jba[j] * N + i, dat[p + i]);
          load(2'd1, jbb[j] * N + i, dat[p + jg[j] * N + i]);
          load(2'd2, jba[j] * N + i, dat[p + 2 * jg[j] * N + i]);
          if (ld_refused) begin errors++; $display("FAIL job %0d: a valid residue was refused", j); end
        end
        dispatch(ntt_desc(jg[j], jba[j], jbb[j], jbc[j], 4'd6), 4'(j), ok);
        if (!ok) begin errors++; $display("FAIL job %0d: no completion", j); continue; end
        if (st_seen !== 3'd0 || eng_done_tag !== 4'(j)) begin
          errors++; $display("FAIL job %0d: status %0d tag %0d", j, st_seen, eng_done_tag);
        end
        // ---- results, read from the cycle done was seen -------------------
        for (i = 0; i < jg[j] * RPG; i++) begin
          read_c(jbc[j] * RPG + i, v);
          if (v !== dat[p + 3 * jg[j] * N + i]) begin
            errors++;
            if (errors < 12)
              $display("FAIL job %0d (%0d groups) word %0d: memory %08x, model %08x",
                       j, jg[j], i, v, dat[p + 3 * jg[j] * N + i]);
          end else checked++;
          if (v >= 32'(mq)) begin errors++; $display("FAIL job %0d word %0d: %08x is not reduced", j, i, v); end
        end
        p += 3 * jg[j] * N + jg[j] * RPG;
        ran++;
      end else begin
        // ---- a job that must be refused ----------------------------------
        for (i = 0; i < DEPTH * RPG; i++) csnap[i] = dut.u_c.mem[i];
        dispatch(ntt_desc(jg[j], jba[j], jbb[j], jbc[j], jkind[j] == 2 ? 4'd3 : 4'd6), 4'(j), ok);
        if (!ok || st_seen !== 3'(jst[j]) || eng_done_tag !== 4'(j)) begin
          errors++; $display("FAIL job %0d: expected refusal %0d, got done=%0d status %0d",
                             j, jst[j], ok, st_seen);
        end
        repeat (4) @(negedge clk);
        for (i = 0; i < DEPTH * RPG; i++)
          if (dut.u_c.mem[i] !== csnap[i]) begin
            errors++; $display("FAIL job %0d: a refused job wrote C word %0d", j, i);
            break;
          end
        if (!eng_ready) begin
          repeat (4) @(negedge clk);
          if (!eng_ready) begin errors++; $display("FAIL job %0d: engine not free after refusal", j); end
        end
      end
    end
    if (p != nwords) begin errors++; $display("FAIL: read %0d model words of %0d", p, nwords); end

    // ---- the host may not write a bank the engine owns (audit R8) ----------
    // GO groups of a = 5, b = 1, w = 1 (y0 = 6, y1 = 4) while the host writes
    // a VALID residue (7) into A, B, W and junk into C on every cycle, aimed at
    // this job's operands and results. Results must be exact, operands
    // unchanged, and every one of those writes reported refused.
    begin
      localparam int GO = 64, BO = 128, CO = 64;
      int hammer, bad, refused_n;
      for (i = 0; i < GO * N; i++) begin
        load(2'd0, BO * N + i, 32'd5); load(2'd1, BO * N + i, 32'd1); load(2'd2, BO * N + i, 32'd1);
      end
      clear_seen = 1; @(negedge clk); clear_seen = 0;
      while (!eng_ready) @(negedge clk);
      eng_wd = ntt_desc(GO, BO, BO, CO, 4'd6); eng_tag = 4'd11; eng_valid = 1;
      @(negedge clk); eng_valid = 0;
      hammer = 0; refused_n = 0;
      // stop on the cycle the completion is reported: from then on the host owns the banks again
      while (!done_seen && !eng_done && hammer < 8000) begin
        ld_we = 1; ld_bank = 2'(hammer % 4);
        ld_addr = (hammer % 4 == 3) ? LAW'(CO * RPG + (hammer * 5) % (GO * RPG))
                                    : LAW'(BO * N + (hammer * 7) % (GO * N));
        ld_data = (hammer % 4 == 3) ? 32'h7F7F7F7F : 32'd7;
        @(negedge clk);
        if (ld_refused) refused_n++;
        hammer++;
      end
      ld_we = 0;
      @(negedge clk); if (ld_refused) refused_n++;
      if (!done_seen) begin errors++; $display("FAIL R8: the job never completed under host writes"); end
      bad = 0;
      for (i = 0; i < GO * RPG; i++)
        if (dut.u_c.mem[CO * RPG + i] !== ((i % 2) ? 32'd4 : 32'd6)) bad++;
      if (bad) begin errors++; $display("FAIL R8: %0d of %0d results corrupted by host writes during the job", bad, GO * RPG); end
      bad = 0;
      for (i = 0; i < GO; i++)
        if (dut.g_lane[0].u_a.mem[BO + i] !== 5 || dut.g_lane[3].u_b.mem[BO + i] !== 1 ||
            dut.g_lane[2].u_w.mem[BO + i] !== 1) bad++;
      if (bad) begin errors++; $display("FAIL R8: %0d operand entries overwritten while the engine owned them", bad); end
      if (refused_n != hammer) begin
        errors++; $display("FAIL R8: %0d of %0d host writes during the job were reported refused", refused_n, hammer);
      end
      $display("R8: %0d host writes during a %0d-group job; results and operands intact", hammer, GO);
    end

    // ---- the load boundary ------------------------------------------------
    load(2'd0, 0, 32'(mq));                // == q
    if (!ld_refused) begin errors++; $display("FAIL: a residue equal to q was written"); end
    load(2'd0, 0, 32'h8000_0001);          // bits above q's width
    if (!ld_refused) begin errors++; $display("FAIL: a word with high bits set was written"); end
    load(2'd1, DEPTH * N, 32'd1);          // one word past the B bank
    if (!ld_refused) begin errors++; $display("FAIL: a load past the end of B was written"); end
    load(2'd3, DEPTH * RPG, 32'd1);        // one word past the C bank (wraps the address)
    if (!ld_refused && LAW > $clog2(DEPTH * RPG)) begin
      errors++; $display("FAIL: a load past the end of C was written");
    end
    load(2'd0, 0, 32'(mq - 1));            // q-1 is legal
    if (ld_refused) begin errors++; $display("FAIL: the residue q-1 was refused"); end

    // ---- reset in the middle of a job, then a clean job --------------------
    for (i = 0; i < 64 * N; i++) begin
      load(2'd0, i, 32'(i % mq)); load(2'd1, i, 32'd1); load(2'd2, i, 32'd1);
    end
    clear_seen = 1; @(negedge clk); clear_seen = 0;
    while (!eng_ready) @(negedge clk);
    eng_wd = ntt_desc(64, 0, 0, 0, 4'd6); eng_tag = 4'd9; eng_valid = 1;
    @(negedge clk); eng_valid = 0;
    repeat (37) @(negedge clk);            // mid-stream, mid-serialiser
    rst_n = 0; repeat (3) @(negedge clk); rst_n = 1; repeat (3) @(negedge clk);
    if (!eng_ready) begin errors++; $display("FAIL: engine not ready after a mid-job reset"); end
    // operand banks keep their contents across reset (they are memories)
    dispatch(ntt_desc(1, 0, 0, 0, 4'd6), 4'd10, ok);
    if (!ok || st_seen !== 3'd0) begin errors++; $display("FAIL: no clean job after the reset"); end
    else begin
      // a = 0..3, b = 1, w = 1: y0 = a + 1, y1 = a - 1 mod q
      for (i = 0; i < N; i++) begin
        logic [31:0] y0, y1;
        read_c(2 * i, y0); read_c(2 * i + 1, y1);
        if (y0 !== 32'((i + 1) % mq) || y1 !== 32'((i + mq - 1) % mq)) begin
          errors++; $display("FAIL: after reset, lane %0d gave (%0d, %0d)", i, y0, y1);
        end
      end
    end

    if (errors) begin
      $display("FAIL tb_hydra_dma_ntt: %0d errors (q=%0d)", errors, mq); $fatal(1);
    end
    $display("PASS tb_hydra_dma_ntt: q=%0d, %0d jobs run and %0d refused as they should be, %0d result words exact from the cycle of completion; load and range checks hold",
             mq, ran, njobs - ran, checked);
    $finish;
  end
endmodule
`default_nettype wire
