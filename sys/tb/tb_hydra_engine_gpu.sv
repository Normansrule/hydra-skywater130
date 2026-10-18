// =============================================================================
// tb_hydra_engine_gpu.sv -- real Pixelstorm kernels over a HYDRA bank
// =============================================================================
// The host side of the engine contract, nothing more: load the kernel and
// its parameters, fill the bank, launch one descriptor, wait for done, read
// the bank back. The expected bank comes from Pixelstorm's own JavaScript
// model (tools/gpu_vectors.js), not from anything in this repository.
//
//   +dir=<vector dir>   one kernel: imem.hex, cmem.hex, init.hex, expect.hex, job.txt
//   +neg                also run the refusals and the ownership/range checks
//
// Checks, for every kernel:
//   * job_status OK, done exactly once, with the descriptor's tag
//   * every word of the bank equals the model's, read back the cycle after
//     done (so "done" means "in the bank")
//   * no bank write by the engine after done (the completion-after-last-
//     write rule, watched directly)
// and with +neg:
//   * no program loaded, grid 0, block 0, block 33: each refused (status 1),
//     done still reported with its tag, and the GPU never launched
//   * a host bank write during a job is refused and changes nothing
//   * a kernel pointed past the end of the bank finishes with status 2
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_hydra_engine_gpu;
  localparam int AW = 12, DEPTH = 1 << AW;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic         eng_valid = 0;
  wire          eng_ready;
  logic [127:0] eng_wd = '0;
  logic [3:0]   eng_tag = '0;
  wire          eng_done;
  wire  [3:0]   eng_done_tag;
  wire  [1:0]   job_status;
  logic         prog_we = 0, cons_we = 0, ld_we = 0;
  logic [9:0]   prog_addr = '0;
  logic [3:0]   cons_addr = '0;
  logic [AW-1:0] ld_addr = '0, rd_addr = '0;
  logic [31:0]  prog_data = '0, cons_data = '0, ld_data = '0;
  wire          ld_refused;
  wire  [31:0]  rd_data, perf_cycles;

  hydra_engine_gpu #(.AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd), .eng_tag(eng_tag),
    .eng_done(eng_done), .eng_done_tag(eng_done_tag), .job_status(job_status),
    .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
    .cons_we(cons_we), .cons_addr(cons_addr), .cons_data(cons_data),
    .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data), .ld_refused(ld_refused),
    .rd_addr(rd_addr), .rd_data(rd_data), .perf_cycles(perf_cycles));

  integer errors = 0, checks = 0;
  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin errors++; if (errors < 20) $display("FAIL: %s", what); end
  endtask

  initial begin #200_000_000; $display("FAIL tb_hydra_engine_gpu: watchdog"); $fatal(1); end

  // ---- watchers ---------------------------------------------------------------
  // The GPU launches only when told to; a refused job must not launch it.
  integer launches = 0;
  always @(posedge clk) if (dut.gpu_launch) launches++;
  // After done, the engine must not write the bank until the next job.
  bit after_done = 0;
  integer late_writes = 0;
  always @(posedge clk) if (after_done && dut.b_we && !dut.host_we) late_writes++;

  // ---- vectors ------------------------------------------------------------------
  logic [31:0] imem [1024];
  logic [31:0] cmem [16];
  logic [31:0] init [DEPTH];
  logic [31:0] expect_m [DEPTH];
  integer grid, block, nwords;
  string dir;

  task automatic load_vectors();
    integer fd, r;
    for (int i = 0; i < 1024; i++) imem[i] = 32'd0;
    $readmemh({dir, "/imem.hex"}, imem);
    $readmemh({dir, "/cmem.hex"}, cmem);
    $readmemh({dir, "/init.hex"}, init);
    $readmemh({dir, "/expect.hex"}, expect_m);
    fd = $fopen({dir, "/job.txt"}, "r");
    if (fd == 0) begin $display("FAIL: cannot open %s/job.txt", dir); $fatal(1); end
    r = $fscanf(fd, "%d %d %d", grid, block, nwords);
    $fclose(fd);
  endtask

  task automatic host_program();
    for (int i = 0; i < nwords; i++) begin
      @(posedge clk); prog_we <= 1; prog_addr <= 10'(i); prog_data <= imem[i];
    end
    @(posedge clk); prog_we <= 0;
  endtask
  task automatic host_params(input int c2_override = -1);
    for (int i = 0; i < 16; i++) begin
      @(posedge clk); cons_we <= 1; cons_addr <= 4'(i);
      cons_data <= (i == 2 && c2_override >= 0) ? 32'(c2_override) : cmem[i];
    end
    @(posedge clk); cons_we <= 0;
  endtask
  task automatic host_fill();
    for (int i = 0; i < DEPTH; i++) begin
      @(posedge clk); ld_we <= 1; ld_addr <= AW'(i); ld_data <= init[i];
    end
    @(posedge clk); ld_we <= 0;
  endtask

  // Launch one job and wait for its single done. Returns the status.
  task automatic run_job(input int g, input int b, input logic [3:0] tag,
                         output logic [1:0] st, input bit poke_bank = 0);
    integer t, dones;
    while (!eng_ready) @(posedge clk);
    @(posedge clk);
    eng_valid <= 1; eng_tag <= tag;
    eng_wd <= '0;
    eng_wd[116:101] <= 16'(g);
    eng_wd[100:85]  <= 16'(b);
    @(posedge clk);
    eng_valid <= 0;
    after_done = 0;
    t = 0; dones = 0;
    while (!eng_done) begin
      @(posedge clk); t++;
      if (poke_bank && t == 20) begin            // a host write in the middle of the job
        ld_we <= 1; ld_addr <= '0; ld_data <= 32'hDEAD_BEEF;
      end else if (poke_bank && t == 21) begin
        ld_we <= 0;
        @(negedge clk); check(ld_refused === 1'b1, "host bank write during a job not refused");
      end
      if (t > 5_000_000) begin $display("FAIL: job never completed"); $fatal(1); end
    end
    st = job_status;
    check(eng_done_tag === tag, $sformatf("done tag %0d, sent %0d", eng_done_tag, tag));
    after_done = 1;
    @(posedge clk);
    check(!eng_done, "done reported for more than one cycle");
  endtask

  task automatic compare(input string what);
    integer bad;
    bad = 0;
    // the read is registered: the address goes in before an edge and the
    // word is on rd_data just after it
    for (int i = 0; i < DEPTH; i++) begin
      rd_addr <= AW'(i);
      @(posedge clk); #1;
      if (rd_data !== expect_m[i]) begin
        bad++;
        if (bad <= 5) $display("  word %0d: bank %08x, model %08x", i, rd_data, expect_m[i]);
      end
    end
    check(bad == 0, $sformatf("%s: %0d of %0d words differ from Pixelstorm's model", what, bad, DEPTH));
  endtask

  logic [1:0] st;
  integer l0;
  initial begin
    if (!$value$plusargs("dir=%s", dir)) begin $display("FAIL: +dir= not given"); $fatal(1); end
    load_vectors();
    repeat (4) @(posedge clk); rst_n = 1;
    repeat (4) @(posedge clk);

    if ($test$plusargs("neg")) begin
      // ---- refusals, before and after a program exists -----------------------
      l0 = launches;
      run_job(grid, block, 4'd1, st);
      check(st == 2'd1, "launch with no program loaded was not refused");
      host_program();
      host_params();
      run_job(0, block, 4'd2, st);  check(st == 2'd1, "grid 0 not refused");
      run_job(grid, 0, 4'd3, st);   check(st == 2'd1, "block 0 not refused");
      run_job(grid, 33, 4'd4, st);  check(st == 2'd1, "block 33 (more than one SM holds) not refused");
      check(launches == l0, $sformatf("a refused job launched the GPU (%0d launches)", launches - l0));
    end

    // ---- the kernel, checked against the model ---------------------------------
    host_program();
    host_params();
    host_fill();
    l0 = launches;
    run_job(grid, block, 4'd5, st, $test$plusargs("neg"));
    check(st == 2'd0, $sformatf("job status %0d, expected 0 (OK)", st));
    check(launches == l0 + 1, "the GPU was not launched exactly once");
    compare(dir);
    check(late_writes == 0, $sformatf("%0d bank writes by the engine after done", late_writes));
    $display("%s: grid %0d block %0d, %0d GPU cycles", dir, grid, block, perf_cycles);

    if ($test$plusargs("neg")) begin
      // ---- the same kernel pointed past the end of the bank --------------------
      host_params(DEPTH - 6);                    // output array starts six words from the end
      host_fill();
      run_job(grid, block, 4'd6, st);
      check(st == 2'd2, $sformatf("kernel writing past the bank finished with status %0d, expected 2", st));
    end

    if (errors) begin $display("FAIL tb_hydra_engine_gpu: %0d of %0d checks", errors, checks); $fatal(1); end
    $display("PASS tb_hydra_engine_gpu: %s, %0d checks", dir, checks);
    $finish;
  end
endmodule

`default_nettype wire
