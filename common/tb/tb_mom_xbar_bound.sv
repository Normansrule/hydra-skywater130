// =============================================================================
// tb_mom_xbar_bound.sv -- the crossbar at the edges of its engine count
// =============================================================================
// SkyWater 130 audit RTL-08 (2026-10-11). The range check compared the engine
// number against NENG truncated to ENGW bits, so NENG = 8 with ENGW = 3 made
// the bound 0 and every engine "out of range". The five-engine build was not
// affected; this elaborates the crossbar at NENG = 1, 5, 7 and 8 (the most a
// 3-bit engine number can address) and dispatches to every engine number.
// By the crossbar's contract a legal one is forwarded to exactly that engine;
// an illegal one is accepted (so nothing deadlocks), forwarded nowhere, and
// reported on err_bad_engine.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module xbar_probe #(parameter int NENG = 5) (input logic clk, input logic rst_n, output int errors);
  logic             disp_valid = 0;
  logic             disp_accept;
  logic [2:0]       disp_engine = 0;
  logic [3:0]       disp_tag = 0;
  logic [NENG-1:0]  eng_valid, eng_busy;
  logic             comp_valid, err_bad, err_unknown;
  logic [3:0]       comp_tag;
  logic [NENG*4-1:0] eng_tag;
  logic [7:0]       eng_wd;
  mom_xbar #(.NENG(NENG), .NTAG(8), .WD_W(8), .TAGW(4), .ENGW(3)) u (
    .clk(clk), .rst_n(rst_n),
    .disp_valid(disp_valid), .disp_accept(disp_accept), .disp_engine(disp_engine),
    .disp_tag(disp_tag), .disp_wd(8'hA5),
    .comp_valid(comp_valid), .comp_tag(comp_tag),
    .eng_valid(eng_valid), .eng_ready({NENG{1'b1}}), .eng_wd(eng_wd), .eng_tag(eng_tag),
    .eng_done('0), .eng_done_tag('0),
    .eng_busy(eng_busy), .err_bad_engine(err_bad), .err_done_unknown(err_unknown));

  initial begin
    errors = 0;
    @(posedge rst_n); repeat (2) @(negedge clk);
    for (int e = 0; e < 8; e++) begin
      logic took, flagged;
      logic [NENG-1:0] fwd;
      disp_engine = 3'(e); disp_tag = 4'(e); disp_valid = 1;
      #1 took = disp_accept; fwd = eng_valid;
      @(negedge clk);
      disp_valid = 0;
      flagged = err_bad;
      if (e < NENG) begin
        if (!took || fwd !== (NENG'(1) << e)) begin
          errors++; $display("FAIL NENG=%0d: engine %0d was not forwarded (accept %0d, valid %b)", NENG, e, took, fwd);
        end
        if (flagged) begin errors++; $display("FAIL NENG=%0d: engine %0d flagged as bad", NENG, e); end
      end else begin
        if (fwd !== '0) begin errors++; $display("FAIL NENG=%0d: engine %0d does not exist but was forwarded", NENG, e); end
        if (!took || !flagged) begin
          errors++; $display("FAIL NENG=%0d: engine %0d does not exist: accept %0d, flagged %0d", NENG, e, took, flagged);
        end
      end
      @(negedge clk);
    end
  end
endmodule

module tb_mom_xbar_bound;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int e1, e5, e7, e8;
  xbar_probe #(.NENG(1)) p1 (.clk(clk), .rst_n(rst_n), .errors(e1));
  xbar_probe #(.NENG(5)) p5 (.clk(clk), .rst_n(rst_n), .errors(e5));
  xbar_probe #(.NENG(7)) p7 (.clk(clk), .rst_n(rst_n), .errors(e7));
  xbar_probe #(.NENG(8)) p8 (.clk(clk), .rst_n(rst_n), .errors(e8));
  initial begin
    repeat (3) @(negedge clk); rst_n = 1;
    repeat (40) @(negedge clk);
    if (e1 + e5 + e7 + e8) begin
      $display("FAIL tb_mom_xbar_bound: %0d errors", e1 + e5 + e7 + e8); $fatal(1);
    end
    $display("PASS tb_mom_xbar_bound: engines 0..7 at NENG = 1, 5, 7, 8: every legal one taken, every other flagged");
    $finish;
  end
endmodule
`default_nettype wire
