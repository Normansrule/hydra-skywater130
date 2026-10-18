// =============================================================================
// tb_sys_tile_mem.sv -- the dispatcher and the memory-fed array, back to back
// =============================================================================
// Audit R1 (2026-10-11): with the array fed from memory, engine 2's ready,
// done and done-tag were still taken from the LATENCY MODEL, because the
// selector only looked at REAL_TPU. A job could retire ~44 cycles after it
// started, while the array was still computing, and the next job could be
// handed to an array that was not ready for it.
//
// The existing end-to-end test (fpga/tb_fpga_mem.sv) ran one job and then
// polled over a serial port, which takes thousands of cycles -- long enough
// for the real array to finish before anybody looked. This test removes that
// slack:
//
//   * two GEMMs are queued behind HOLD, then released together, so the second
//     arrives the moment the first is dispatched;
//   * the first is long (k = 300: about 300 cycles of real work, against the
//     model's 44), the second short;
//   * on EVERY cycle: a completion the scheduler sees from engine 2 must be
//     the real engine's completion, with its tag, and a dispatch to engine 2
//     must find the real engine ready;
//   * at the INSTANT each tag retires, that job's results must already be in
//     the result memory -- no settling delay, no polling.
//
// The scratchpad has a fixed one-cycle latency, so there is no memory stall
// to randomise; the two jobs' lengths and the queueing stand in for it.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_sys_tile_mem;
  localparam int HALF = 5;
  localparam int KA = 300, KB = 40;            // slices in job A and job B
  localparam int BASE_B = KA;                  // job B's operands follow A's
  localparam int CA = 0, CB = 16;              // result bases
  localparam logic [31:0] EXP_A = 32'(KA * 1 * 1);
  localparam logic [31:0] EXP_B = 32'(KB * 2 * 3);

  logic clk = 0, rst_n = 0;
  logic [7:0] ui = 8'b0000_0100;
  wire  [7:0] uo, uio, uio_oe;
  logic        mem_we = 0;
  logic [1:0]  mem_bank = 0;
  logic [15:0] mem_addr = 0, mem_raddr = 0;
  logic [31:0] mem_wdata = 0;
  wire  [31:0] mem_rdata;
  int errors = 0;
  always #27.5 clk = ~clk;

  hydra_sys_tile #(.TPU_ENGINE(2)) dut (    // 2 = TPU_MEMORY
    .ui_in(ui), .uo_out(uo), .uio_in(8'h00), .uio_out(uio), .uio_oe(uio_oe),
    .ena(1'b1), .clk(clk), .rst_n(rst_n),
    .dbg_checksum(), .dbg_tiles(), .dbg_simd_checksum(), .dbg_simd_jobs(),
    .mem_we(mem_we), .mem_bank(mem_bank), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_raddr(mem_raddr), .mem_rdata(mem_rdata), .mem_refused());

  // ---- SPI host -------------------------------------------------------------
  logic [7:0] rbuf [24];
  logic [7:0] d [24];
  task automatic xfer(input int n);
    ui[2] = 1'b0;
    repeat (2*HALF) @(posedge clk);
    for (int i = 0; i < n; i++) begin
      logic [7:0] rx;
      for (int b = 7; b >= 0; b--) begin
        ui[1] = d[i][b];
        repeat (HALF) @(posedge clk);
        rx = {rx[6:0], uo[0]};
        ui[0] = 1'b1;
        repeat (HALF) @(posedge clk);
        ui[0] = 1'b0;
      end
      rbuf[i] = rx;
    end
    repeat (HALF) @(posedge clk);
    ui[2] = 1'b1;
    repeat (2*HALF) @(posedge clk);
  endtask
  task automatic wr(input logic [6:0] a, input int n, input logic [127:0] v);
    d[0] = {1'b0, a};
    for (int i = 0; i < n; i++) d[i+1] = v[(n-1-i)*8 +: 8];
    xfer(n+1);
  endtask
  task automatic rd(input logic [6:0] a, input int n, output logic [127:0] v);
    d[0] = {1'b1, a};
    for (int i = 1; i <= n; i++) d[i] = 8'h00;
    xfer(n+1);
    v = '0;
    for (int i = 0; i < n; i++) v = (v << 8) | rbuf[i+1];
  endtask
  task automatic load(input logic [1:0] bank, input int addr, input logic [31:0] w);
    @(negedge clk);
    mem_we = 1; mem_bank = bank; mem_addr = 16'(addr); mem_wdata = w;
    @(negedge clk);
    mem_we = 0;
  endtask

  // ---- the R1 invariants, checked on every cycle ------------------------------
  int seen_done2 = 0, real_done = 0, bad_done = 0, bad_admit = 0;
  always @(posedge clk) if (rst_n) begin
    if (dut.memtpu_done) real_done++;
    if (dut.eng_done[2]) begin
      seen_done2++;
      if (!dut.memtpu_done || dut.eng_done_tag[2*4 +: 4] !== dut.memtpu_done_tag) begin
        bad_done++;
        if (bad_done < 4)
          $display("FAIL: at %0t the scheduler saw engine 2 complete tag %0d, but the memory-fed array %s",
                   $time, dut.eng_done_tag[2*4 +: 4],
                   dut.memtpu_done ? "completed a different tag" : "had not completed");
      end
    end
    if (dut.eng_valid[2] && !dut.memtpu_ready) begin
      bad_admit++;
      if (bad_admit < 4)
        $display("FAIL: at %0t a job was handed to engine 2 while the memory-fed array was busy", $time);
    end
  end

  // ---- commit before retirement ------------------------------------------------
  // The moment a tag's busy bit falls, its results must be in the C bank.
  logic [7:0] busy_q = '0;
  int retired = 0;
  function automatic int check_region(input int base, input logic [31:0] want);
    int bad = 0;
    for (int i = 0; i < 16; i++)
      if (dut.g_mem_tpu.u_memtpu.u_c.mem[base + i] !== want) bad++;
    return bad;
  endfunction
  always @(posedge clk) if (rst_n) begin
    for (int t = 0; t < 8; t++)
      if (busy_q[t] && !dut.obs_tag_busy[t]) begin
        int base, nbad; logic [31:0] want;
        // Jobs run in order on the one array, and B is only handed over when
        // the array is free -- so B usually reuses A's tag. Identify the job
        // by the order it retires, not by its tag.
        base = (retired == 0) ? CA : CB;
        want = (retired == 0) ? EXP_A : EXP_B;
        retired++;
        nbad = check_region(base, want);
        if (nbad) begin
          errors++;
          $display("FAIL: job %s (tag %0d) retired at %0t with %0d of 16 results not yet in memory",
                   retired == 1 ? "A" : "B", t, $time, nbad);
        end else
          $display("job %s (tag %0d) retired at %0t with all 16 results already in memory",
                   retired == 1 ? "A" : "B", t, $time);
      end
    busy_q <= dut.obs_tag_busy;
  end

  initial begin #50_000_000; $display("FAIL tb_sys_tile_mem: watchdog"); $fatal(1); end

  logic [127:0] v, desc;
  initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (20) @(posedge clk);

    // operands: job A all ones, job B twos times threes; poison in C
    for (int i = 0; i < KA; i++) begin load(2'd0, i, 32'h01010101); load(2'd1, i, 32'h01010101); end
    for (int i = 0; i < KB; i++) begin load(2'd0, BASE_B + i, 32'h02020202); load(2'd1, BASE_B + i, 32'h03030303); end
    for (int i = 0; i < 32; i++) load(2'd2, i, 32'hDEADBEEF);

    // the array's setup cost 64 -> 2, so the cost model sends GEMMs to it
    wr(7'h0B, 6, {2'b00, 3'd2, 4'd7, 12'd2, 4'd5, 8'd2, 6'b000011, 9'b000011000});
    wr(7'h02, 1, 128'h01);                       // HOLD: queue, do not dispatch

    desc = '0;
    desc[127:124] = 4'd3; desc[123:121] = 3'd0;  // GEMM, INT8
    desc[116:101] = 16'd4; desc[100:85] = 16'd4; desc[84:69] = 16'(KA);
    desc[3 +: 10] = 10'd0; desc[13 +: 10] = 10'd0; desc[23 +: 10] = 10'(CA);
    wr(7'h01, 16, desc); wr(7'h03, 1, 128'h01);
    for (int w = 0; w < 20; w++) begin rd(7'h05, 2, v); if (!v[13]) break; end   // taken by the MOM
    desc[84:69] = 16'(KB);
    desc[3 +: 10] = 10'(BASE_B); desc[13 +: 10] = 10'(BASE_B); desc[23 +: 10] = 10'(CB);
    wr(7'h01, 16, desc); wr(7'h03, 1, 128'h01);
    for (int w = 0; w < 20; w++) begin rd(7'h05, 2, v); if (!v[13]) break; end

    wr(7'h02, 1, 128'h00);                       // release: both dispatch back to back

    for (int w = 0; w < 40000 && retired < 2; w++) @(posedge clk);
    repeat (50) @(posedge clk);

    if (retired != 2) begin errors++; $display("FAIL: %0d of 2 jobs retired", retired); end
    if (check_region(CA, EXP_A) || check_region(CB, EXP_B)) begin
      errors++; $display("FAIL: final results wrong");
    end
    if (dut.g_mem_tpu.u_memtpu.tiles_done !== 16'd2) begin
      errors++; $display("FAIL: the array ran %0d jobs, not 2", dut.g_mem_tpu.u_memtpu.tiles_done);
    end
    if (seen_done2 != 2 || real_done != 2) begin
      errors++;
      $display("FAIL: the scheduler saw %0d completions from engine 2; the array made %0d",
               seen_done2, real_done);
    end
    errors += bad_done + bad_admit;

    if (errors) begin $display("FAIL tb_sys_tile_mem: %0d errors", errors); $fatal(1); end
    $display("PASS tb_sys_tile_mem: 2 back-to-back jobs (k=%0d, k=%0d), every completion the array's own, results in memory at retirement",
             KA, KB);
    $finish;
  end
endmodule
`default_nettype wire
