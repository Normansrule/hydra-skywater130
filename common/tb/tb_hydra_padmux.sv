// =============================================================================
// tb_hydra_padmux.sv -- replays padmux_model.py vectors, exact compare
// =============================================================================
// WHY: the model is written from the contract, so agreement here means the
// RTL implements the contract, not that the RTL agrees with itself. Every
// field is compared every cycle; a summary-only check would hide a single
// wrong bit. The bench also refuses to pass on an empty or short vector file
// (silent-failure pattern: an empty stream once printed "== done").
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_hydra_padmux;
  localparam int NPAD = 5, NALT = 3, SELW = 2;
  localparam logic [NPAD*SELW-1:0] RESET_SEL = 10'h249;  // {2,1,0,2,1}
  localparam int MIN_VECTORS = 1000;

  logic clk = 0, rst_n, cfg_we, cfg_lock, locked_q;
  logic [NPAD*SELW-1:0] cfg_sel, sel_q;
  logic [NPAD*NALT-1:0] alt_out, alt_oe, alt_idle, alt_in;
  logic [NPAD-1:0]      pad_out, pad_oe, pad_in;

  hydra_padmux #(.NPAD(NPAD), .NALT(NALT), .SELW(SELW), .RESET_SEL(RESET_SEL)) dut (.*);

  integer fd, n, errors, r, done;
  logic [31:0] v_rst, v_we, v_sel, v_lock, v_ao, v_aoe, v_aid, v_pin;
  logic [31:0] e_sel, e_lock, e_po, e_poe, e_ai;

  task automatic check(string what, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) begin
      errors++;
      if (errors <= 10) $display("MISMATCH vec %0d %s: got %h exp %h", n, what, got, exp);
    end
  endtask

  initial begin
    fd = $fopen("padmux_vectors.hex", "r");
    if (fd == 0) begin $display("FAIL: no vector file"); $fatal(1); end
    n = 0; errors = 0;
    rst_n = 0; cfg_we = 0; cfg_sel = 0; cfg_lock = 0;
    alt_out = 0; alt_oe = 0; alt_idle = 0; pad_in = 0;
    done = 0;
    while (!$feof(fd) && !done) begin
      r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                  v_rst, v_we, v_sel, v_lock, v_ao, v_aoe, v_aid, v_pin,
                  e_sel, e_lock, e_po, e_poe, e_ai);
      if (r != 13) done = 1;
      else begin
      rst_n = v_rst[0]; cfg_we = v_we[0]; cfg_sel = v_sel; cfg_lock = v_lock[0];
      alt_out = v_ao; alt_oe = v_aoe; alt_idle = v_aid; pad_in = v_pin;
      #1;
      check("sel_q",    32'(sel_q),    e_sel);
      check("locked_q", 32'(locked_q), e_lock);
      check("pad_out",  32'(pad_out),  e_po);
      check("pad_oe",   32'(pad_oe),   e_poe);
      check("alt_in",   32'(alt_in),   e_ai);
      #4 clk = 1; #5 clk = 0;
      n++;
      end
    end
    $fclose(fd);
    if (n < MIN_VECTORS) begin
      $display("FAIL: only %0d vectors replayed (need >= %0d)", n, MIN_VECTORS);
      $fatal(1);
    end
    if (errors) begin
      $display("FAIL: %0d mismatches in %0d vectors", errors, n);
      $fatal(1);
    end
    $display("PASS tb_hydra_padmux: %0d/%0d vectors exact", n, n);
    $finish;
  end
endmodule

`default_nettype wire
