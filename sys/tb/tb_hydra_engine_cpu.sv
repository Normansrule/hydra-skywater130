// =============================================================================
// tb_hydra_engine_cpu.sv -- real Sixfold programs through the HYDRA wrapper
// =============================================================================
// The host side of the engine contract only: load the program into the core's
// memory, launch one descriptor, wait for done, read x0..x31 back through the
// debug port. The expected registers, TOHOST value and cycle count come from
// Sixfold's own cycle-exact model (tools/cpu_vectors.mjs), not from HYDRA code.
//
//   +dir=<vector dir>   prog.hex, regs.txt, info.txt
//   +neg                also: refusals, the cycle limit, host writes refused
//                       while the core runs, and recovery afterwards
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_hydra_engine_cpu;
  parameter bit CACHED = 1'b0;      // -Ptb_hydra_engine_cpu.CACHED=1: Sixfold's caches over block memory
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic         eng_valid = 0;
  wire          eng_ready;
  logic [3:0]   eng_tag = 0;
  wire          eng_done;
  wire  [3:0]   eng_done_tag;
  wire  [1:0]   job_status;
  wire  [63:0]  tohost;
  logic         ld_we = 0, cfg_we = 0, cfg_addr = 0;
  logic [13:0]  ld_addr = 0, rd_addr = 0;
  logic [31:0]  ld_data = 0, cfg_data = 0;
  wire          ld_refused;
  wire  [31:0]  rd_data, perf_cycles;
  logic [4:0]   dbg_reg = 0;
  wire  [63:0]  dbg_data;

  hydra_engine_cpu #(.CACHED(CACHED)) dut (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(128'd0), .eng_tag(eng_tag),
    .eng_done(eng_done), .eng_done_tag(eng_done_tag), .job_status(job_status), .tohost(tohost),
    .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data), .ld_refused(ld_refused),
    .rd_addr(rd_addr), .rd_data(rd_data), .dbg_reg(dbg_reg), .dbg_data(dbg_data),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data), .perf_cycles(perf_cycles));

  integer errors = 0, checks = 0;
  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin errors++; if (errors < 20) $display("FAIL: %s", what); end
  endtask
  initial begin #3_000_000_000; $display("FAIL tb_hydra_engine_cpu: watchdog"); $fatal(1); end

  string dir;
  reg [7:0]  img [0:65535];
  reg [63:0] want [0:31];
  reg [63:0] want_tohost;
  integer    want_cycles, want_cycles_cached, fd, r;
  reg [31:0] entry;

  task automatic cfg(input bit a, input logic [31:0] v);
    @(posedge clk); cfg_we <= 1; cfg_addr <= a; cfg_data <= v;
    @(posedge clk); cfg_we <= 0;
  endtask
  task automatic load_image();
    for (int w = 0; w < 16384; w++) begin
      @(posedge clk); ld_we <= 1; ld_addr <= 14'(w);
      ld_data <= {img[4*w+3], img[4*w+2], img[4*w+1], img[4*w]};
    end
    @(posedge clk); ld_we <= 0;
  endtask
  task automatic run(input logic [3:0] tag, output logic [1:0] st, input int poke_at = -1);
    int t;
    while (!eng_ready) @(posedge clk);
    @(posedge clk); eng_valid <= 1; eng_tag <= tag;
    @(posedge clk); eng_valid <= 0;
    t = 0;
    while (!eng_done) begin
      @(posedge clk); t++;
      if (t == poke_at) begin ld_we <= 1; ld_addr <= 14'h0800; ld_data <= 32'hDEADBEEF; end
      if (t == poke_at + 1) begin ld_we <= 0; @(negedge clk); check(ld_refused === 1'b1, "host write while the core runs not refused"); end
      if (t > 5_000_000) begin $display("FAIL: job never completed"); $fatal(1); end
    end
    st = job_status;
    check(eng_done_tag === tag, $sformatf("done tag %0d, sent %0d", eng_done_tag, tag));
    @(posedge clk);
    check(!eng_done, "done reported for more than one cycle");
  endtask
  task automatic compare_regs(input string what);
    int bad = 0;
    for (int i = 1; i < 32; i++) begin
      dbg_reg = 5'(i); #1;
      if (dbg_data !== want[i]) begin
        bad++; if (bad <= 4) $display("  %s x%0d: core %016x, model %016x", what, i, dbg_data, want[i]);
      end
    end
    check(bad == 0, $sformatf("%s: %0d of 31 registers differ from Sixfold's model", what, bad));
  endtask

  logic [1:0] st;
  initial begin
    if (!$value$plusargs("dir=%s", dir)) begin $display("FAIL: +dir= not given"); $fatal(1); end
    for (int a = 0; a < 65536; a++) img[a] = 8'h00;
    $readmemh({dir, "/prog.hex"}, img);
    // with caches the model's timing differs, and so do registers that read
    // the cycle counter: each build is compared with its own model run
    if (CACHED) $readmemh({dir, "/regs_cached.txt"}, want);
    else        $readmemh({dir, "/regs.txt"}, want);
    fd = $fopen({dir, "/info.txt"}, "r");
    r = $fscanf(fd, "%h %d %h %d", want_tohost, want_cycles, entry, want_cycles_cached);
    if (CACHED) want_cycles = want_cycles_cached;
    $fclose(fd);
    repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

    if ($test$plusargs("neg")) begin
      run(4'd1, st);  check(st == 2'd1, "a launch with no program loaded was not refused");
      load_image();
      cfg(0, entry + 32'd2); run(4'd2, st); check(st == 2'd1, "a misaligned entry address was not refused");
      cfg(0, 32'h0001_0000); run(4'd3, st); check(st == 2'd1, "an entry outside the memory was not refused");
      cfg(0, entry); cfg(1, 32'd40); run(4'd4, st);
      check(st == 2'd2, $sformatf("a program longer than the cycle limit finished with status %0d, expected 2", st));
      cfg(1, 32'd4_000_000);
      load_image();                    // the stopped run may have written memory
    end else begin
      load_image();
      cfg(0, entry);
    end

    run(4'd5, st, $test$plusargs("neg") ? 5 : -1);
    check(st == 2'd0, $sformatf("job status %0d, expected 0", st));
    check(tohost === want_tohost, $sformatf("TOHOST %0h, model %0h", tohost, want_tohost));
    compare_regs(dir);
    $display("%s: %0d cycles in the core, %0d in Sixfold's model (%s)", dir, perf_cycles, want_cycles,
             CACHED ? "caches on" : "no caches");
    check(perf_cycles == want_cycles, "cycle count differs from Sixfold's cycle-exact model");

    // a second job on the same core must start clean and give the same answer
    load_image();
    run(4'd6, st);
    check(st == 2'd0, "second run status");
    compare_regs({dir, " (second run)"});

    if (errors) begin $display("FAIL tb_hydra_engine_cpu: %0d of %0d checks", errors, checks); $fatal(1); end
    $display("PASS tb_hydra_engine_cpu: %s, %0d checks", dir, checks);
    $finish;
  end
endmodule
`default_nettype wire
