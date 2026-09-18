// =============================================================================
// tb_mom_xbar.sv -- replays xbar_model.py vectors, exact compare every cycle
// =============================================================================
// The model includes MISBEHAVING engines (a done for a tag they were not
// given, a done while idle). Those are exactly the cases the formal proofs
// assume away, so they have to be covered here or they are covered nowhere.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_mom_xbar;
  localparam int NENG = 5, NTAG = 8, WD_W = 128, TAGW = 4, ENGW = 3;
  localparam int MIN_VECTORS = 1000;

  logic clk = 0, rst_n, disp_valid, disp_accept, comp_valid;
  logic [ENGW-1:0] disp_engine;
  logic [TAGW-1:0] disp_tag, comp_tag;
  logic [WD_W-1:0] disp_wd = 128'h0;
  logic [NENG-1:0] eng_valid, eng_ready, eng_done, eng_busy;
  logic [WD_W-1:0] eng_wd;
  logic [NENG*TAGW-1:0] eng_tag, eng_done_tag;
  logic err_bad_engine, err_done_unknown;

  mom_xbar #(.NENG(NENG), .NTAG(NTAG), .WD_W(WD_W), .TAGW(TAGW), .ENGW(ENGW)) dut (.*);

  integer fd, n = 0, errors = 0, r, done_flag = 0;
  logic [31:0] v_rst, v_dv, v_de, v_dt, v_rdy, v_dn, v_dnt;
  logic [31:0] e_acc, e_ev, e_cv, e_ct, e_busy, e_eb, e_eu;

  task automatic chk(string what, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) begin
      errors++;
      if (errors <= 10) $display("MISMATCH vec %0d %s: got %h exp %h", n, what, got, exp);
    end
  endtask

  initial begin
    fd = $fopen("xbar_vectors.hex", "r");
    if (fd == 0) begin $display("FAIL: no vector file"); $fatal(1); end
    rst_n = 0; disp_valid = 0; disp_engine = 0; disp_tag = 0;
    eng_ready = 0; eng_done = 0; eng_done_tag = 0;
    while (!$feof(fd) && !done_flag) begin
      r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                  v_rst, v_dv, v_de, v_dt, v_rdy, v_dn, v_dnt,
                  e_acc, e_ev, e_cv, e_ct, e_busy, e_eb, e_eu);
      if (r != 14) done_flag = 1;
      else begin
        rst_n = v_rst[0]; disp_valid = v_dv[0]; disp_engine = v_de[ENGW-1:0];
        disp_tag = v_dt[TAGW-1:0]; eng_ready = v_rdy[NENG-1:0];
        eng_done = v_dn[NENG-1:0]; eng_done_tag = v_dnt[NENG*TAGW-1:0];
        #1;
        chk("disp_accept", 32'(disp_accept), e_acc);
        chk("eng_valid",   32'(eng_valid),   e_ev);
        chk("comp_valid",  32'(comp_valid),  e_cv);
        if (e_cv[0]) chk("comp_tag", 32'(comp_tag), e_ct);
        chk("eng_busy",    32'(eng_busy),    e_busy);
        chk("err_bad",     32'(err_bad_engine),   e_eb);
        chk("err_unknown", 32'(err_done_unknown), e_eu);
        #4 clk = 1; #5 clk = 0;
        n++;
      end
    end
    $fclose(fd);
    if (n < MIN_VECTORS) begin $display("FAIL: only %0d vectors", n); $fatal(1); end
    if (errors) begin $display("FAIL: %0d mismatches in %0d vectors", errors, n); $fatal(1); end
    $display("PASS tb_mom_xbar: %0d/%0d vectors exact", n, n);
    $finish;
  end
endmodule
`default_nettype wire
