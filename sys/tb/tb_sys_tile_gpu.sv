// =============================================================================
// tb_sys_tile_gpu.sv -- the scheduler choosing between CPU, vector, TPU and GPU
// =============================================================================
// The chip's dispatcher with six slots (NENG = 6): engine 5 is the Pixelstorm
// GPU (sys/rtl/hydra_engine_gpu.sv), engine 2 the memory-fed systolic array,
// the others latency models. Everything goes in through the SPI register map
// and the memory port, as a host would do it.
//
//   1. a 32x32x64 INT32 matrix multiply: the TPU cannot take INT32 (masked
//      out before cost), and of the engines that can, the GPU's nominal row
//      is cheapest -- so the scheduler dispatches it to engine 5. The launch
//      shape was loaded beforehand; the GPU runs Pixelstorm's 07_matmul
//      kernel, and at the instant the tag retires the bank must equal
//      Pixelstorm's own model's result, word for word
//   2. the same shape in INT8: the GPU is not eligible (32-bit only), so it
//      must NOT go to engine 5; the array takes it
//   3. every completion the scheduler sees from engine 5 is the GPU's own
//
//   +dir=<vector dir>   07_matmul from tools/gpu_vectors.js
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_sys_tile_gpu;
  localparam int HALF = 5;
  localparam int GDEPTH = 4096;

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

  hydra_sys_tile #(.NENG(6), .TPU_ENGINE(2), .GPU_ENGINE(1)) dut (
    .ui_in(ui), .uo_out(uo), .uio_in(8'h00), .uio_out(uio), .uio_oe(uio_oe),
    .ena(1'b1), .clk(clk), .rst_n(rst_n),
    .dbg_checksum(), .dbg_tiles(), .dbg_simd_checksum(), .dbg_simd_jobs(),
    .mem_we(mem_we), .mem_bank(mem_bank), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_raddr(mem_raddr), .mem_rdata(mem_rdata), .mem_refused());

  // ---- SPI host (as tb_sys_tile_mem) ------------------------------------------
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

  // ---- vectors ----------------------------------------------------------------
  string dir;
  logic [31:0] imem [1024];
  logic [31:0] cmem [16];
  logic [31:0] init [GDEPTH];
  logic [31:0] expect_m [GDEPTH];
  integer grid, block, nwords;

  // ---- every cycle: engine 5's completions are the GPU's own --------------------
  int disp5 = 0, done5 = 0, bad5 = 0, int8_to_gpu = 0;
  bit int8_phase = 0;
  always @(posedge clk) if (rst_n) begin
    if (dut.eng_valid[5]) begin
      disp5++;
      if (int8_phase) int8_to_gpu++;
    end
    if (dut.eng_done[5]) begin
      done5++;
      if (!dut.gpu_done || dut.eng_done_tag[5*4 +: 4] !== dut.gpu_done_tag) bad5++;
    end
  end

  // ---- at the instant a GPU job retires, the bank is complete ------------------
  logic [7:0] busy_q = '0;
  logic [3:0] gpu_tag = 4'hF;
  bit gpu_pending = 0;                 // a tag handed to the GPU, not yet retired
  int gpu_retired = 0, gpu_bad_words = -1;
  always @(posedge clk) if (rst_n) begin
    if (dut.eng_valid[5]) begin gpu_tag <= dut.eng_tag[5*4 +: 4]; gpu_pending <= 1; end
    for (int t = 0; t < 8; t++)
      if (busy_q[t] && !dut.obs_tag_busy[t] && gpu_pending && t == gpu_tag) begin
        int bad = 0;
        gpu_pending <= 0;
        for (int a = 0; a < GDEPTH; a++)
          if (dut.g_real_gpu.u_gpu.u_bank.mem[a] !== expect_m[a]) bad++;
        gpu_bad_words = bad;
        gpu_retired++;
        $display("GPU job (tag %0d) retired at %0t: %0d of %0d bank words differ from Pixelstorm's model",
                 t, $time, bad, GDEPTH);
      end
    busy_q <= dut.obs_tag_busy;
  end

  // +dbg: print each engine's predicted cost and capability at every dispatch
  always @(posedge clk) if (rst_n && $test$plusargs("dbg") && dut.disp_valid && dut.disp_accept)
    for (int e = 0; e < 6; e++)
      $display("  select -> %0d | engine %0d cost %0d valid %0b capable %0b", dut.u_mom.sel_eng, e,
               dut.u_mom.cost_q[e*32 +: 32], dut.u_mom.cvalid_q[e], dut.u_mom.ccapable_q[e]);

  initial begin #200_000_000; $display("FAIL tb_sys_tile_gpu: watchdog"); $fatal(1); end

  logic [127:0] v, desc;
  integer fd, r;
  initial begin
    if (!$value$plusargs("dir=%s", dir)) begin $display("FAIL: +dir= not given"); $fatal(1); end
    for (int i = 0; i < 1024; i++) imem[i] = 32'd0;
    $readmemh({dir, "/imem.hex"}, imem);
    $readmemh({dir, "/cmem.hex"}, cmem);
    $readmemh({dir, "/init.hex"}, init);
    $readmemh({dir, "/expect.hex"}, expect_m);
    fd = $fopen({dir, "/job.txt"}, "r");
    r = $fscanf(fd, "%d %d %d", grid, block, nwords);
    $fclose(fd);

    repeat (5) @(posedge clk); rst_n = 1;
    repeat (20) @(posedge clk);

    // the host loads the GPU over the memory port: program, parameters, data
    for (int i = 0; i < nwords; i++) load(2'd3, 16'h4000 | i, imem[i]);
    for (int i = 0; i < 16; i++)     load(2'd3, 16'h8000 | i, cmem[i]);
    for (int i = 0; i < GDEPTH; i++) load(2'd3, i, init[i]);
    load(2'd3, 16'hC000, 32'(grid));                   // launch shape
    load(2'd3, 16'hC001, 32'(block));

    // ---- 1. INT32 matrix multiply -> the GPU ---------------------------------
    desc = '0;
    desc[127:124] = 4'd3; desc[123:121] = 3'd2;      // GEMM, INT32
    desc[116:101] = 16'd32; desc[100:85] = 16'd32; desc[84:69] = 16'd64;   // the work, for the cost model
    wr(7'h01, 16, desc); wr(7'h03, 1, 128'h01);
    for (int w = 0; w < 400000 && gpu_retired < 1; w++) @(posedge clk);
    if (disp5 != 1) begin errors++; $display("FAIL: the INT32 GEMM went to engine %0d, not the GPU (%0d dispatches to 5)",
                                              dut.r_last_engine, disp5); end
    if (gpu_retired != 1) begin errors++; $display("FAIL: the GPU job never retired"); end
    else if (gpu_bad_words != 0) begin errors++; $display("FAIL: bank not complete at retirement"); end

    // ---- 2. the same shape in INT8 -> not the GPU -----------------------------
    int8_phase = 1;
    desc[123:121] = 3'd0;                             // INT8
    desc[116:101] = 16'd4; desc[100:85] = 16'd4;      // a shape the 4x4 array accepts
    wr(7'h01, 16, desc); wr(7'h03, 1, 128'h01);
    repeat (20000) @(posedge clk);
    if (int8_to_gpu != 0) begin errors++; $display("FAIL: an INT8 job was dispatched to the GPU, which is 32-bit only"); end
    rd(7'h06, 2, v);

    if (bad5) begin errors += bad5; $display("FAIL: %0d engine-5 completions were not the GPU's", bad5); end
    if (done5 != 1) begin errors++; $display("FAIL: %0d completions from engine 5, expected 1", done5); end

    if (errors) begin $display("FAIL tb_sys_tile_gpu: %0d errors", errors); $fatal(1); end
    $display("PASS tb_sys_tile_gpu: six slots; INT32 GEMM scheduled to the GPU, its bank equal to Pixelstorm's model at retirement; INT8 kept off the GPU");
    $finish;
  end
endmodule
`default_nettype wire
