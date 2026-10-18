// =============================================================================
// tb_cost_cal.sv -- the cost and calibration arithmetic against EXACT answers
// =============================================================================
// SkyWater 130 audit, MODEL-01 and MODEL-02 (2026-10-11).
//
// MODEL-01. mom_cost_engine multiplies the predicted time by the calibration
//   factor through a 16-bit mantissa. Its comment promised error below one
//   part in 65,536, and the old reference model was changed to MIRROR the
//   hardware, so the two agreed and nothing checked the claim. Here the
//   oracle is the exact product floor(t_pred * k / 64), and every value
//   around every exponent boundary (2^n - 1, 2^n, 2^n + 1 for n = 0..31) plus
//   random values is checked at every k the calibrator can hold. The
//   contract tested: t_cal <= exact, and exact - t_cal <= exact / 256 + 1
//   (under 0.4 %, a quarter of the calibrator's smallest 1.56 % step), and
//   saturation to COST_SAT exactly when the exact value does not fit.
//
// MODEL-02. mom_calibrate recomputes floor(t_pred * k / 64) to decide which
//   way to move k. Taking only 32 bits of that product let it wrap: a huge
//   prediction compared as a tiny one and k moved the wrong way. Also, an
//   update with an engine or op-class index outside the table must change
//   nothing and not count as an update.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_cost_cal;
  import mom_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0, checked = 0;

  // ---------------------------------------------------------------- MODEL-01
  logic [7:0] k_cal = 8'd64;
  wire [COST_W-1:0] cost, t_pred_o;
  wire valid, capable;

  mom_cost_engine u_cost (
    .clk(clk), .rst_n(rst_n), .adv(1'b0),
    .log2_w(8'd0), .bytes_q(24'd0), .log2_i(9'sd0),
    .dtype(dtype_e'(0)), .op_class(OPC_GEMM), .lat_hint(lat_hint_e'(0)),
    .lambda_sh(4'd0), .param('0), .k_cal(k_cal), .queue_depth(8'd0),
    .engine_busy_full(1'b0), .bw_dma_log2(4'd0), .eps_mem(4'd0), .e_shift(4'd0),
    .cost(cost), .t_pred(t_pred_o), .valid(valid), .capable(capable));

  logic [31:0] tp_drive = '0;          // module scope: force needs a static source
  task automatic check_cal(input logic [31:0] tp, input logic [7:0] k);
    logic [47:0] exact;
    logic [31:0] got;
    tp_drive = tp;
    k_cal = k;
    #1;
    got   = u_cost.t_cal;
    exact = ({16'd0, tp} * {40'd0, k}) >> KCAL_SHIFT;
    if (exact > 48'hFFFF_FFFF) begin
      if (got !== COST_SAT) begin
        errors++;
        if (errors < 10) $display("FAIL MODEL-01: t_pred=%0d k=%0d exact=%0d does not fit, got %0d (expected saturation)", tp, k, exact, got);
      end else checked++;
    end else if (got > exact[31:0] || (exact[31:0] - got) > (exact[31:0] >> 8) + 1) begin
      errors++;
      if (errors < 10)
        $display("FAIL MODEL-01: t_pred=%0d k=%0d exact=%0d got %0d (%0.2f%% low)",
                 tp, k, exact, got, 100.0 * (exact[31:0] - got) / exact[31:0]);
    end else checked++;
  endtask

  // ---------------------------------------------------------------- MODEL-02
  logic        upd_valid = 0, freeze = 0, reset_factors = 0;
  logic [2:0]  upd_engine = 0;
  opclass_e    upd_opclass = OPC_SCALAR, rd_opclass = OPC_SCALAR;
  logic [31:0] upd_meas = 0, upd_pred = 0;
  wire  [ENG_N-1:0][7:0] rd_k;
  wire  [15:0] upd_count;
  wire         last_dir;

  mom_calibrate u_cal (
    .clk(clk), .rst_n(rst_n), .freeze(freeze), .reset_factors(reset_factors),
    .rd_opclass(rd_opclass), .rd_k(rd_k),
    .upd_valid(upd_valid), .upd_engine(upd_engine), .upd_opclass(upd_opclass),
    .upd_t_measured(upd_meas), .upd_t_predicted(upd_pred),
    .upd_count(upd_count), .last_dir(last_dir));

  task automatic update(input logic [2:0] e, input opclass_e c, input logic [31:0] meas, input logic [31:0] pred);
    @(negedge clk);
    upd_valid = 1; upd_engine = e; upd_opclass = c; upd_meas = meas; upd_pred = pred;
    @(negedge clk);
    upd_valid = 0;
  endtask

  initial begin
    logic [31:0] tp, r;
    logic [7:0]  k0, k1;
    logic [15:0] n0;
    logic [7:0]  snap [ENG_N][9];

    // ---- MODEL-01 ---------------------------------------------------------
    force u_cost.t_pred_q = tp_drive;
    for (int k = 4; k <= 255; k++) begin
      for (int n = 0; n < 32; n++) begin
        check_cal(32'd1 << n, 8'(k));
        check_cal((32'd1 << n) - 32'd1, 8'(k));
        check_cal((32'd1 << n) + 32'd1, 8'(k));
      end
      check_cal(32'd511, 8'(k));
      check_cal(32'd131071, 8'(k));
      check_cal(32'hFFFF_FFFF, 8'(k));
      for (int i = 0; i < 64; i++) begin
        r = $urandom;
        check_cal(r >> (r[4:0]), 8'(k));
      end
    end
    release u_cost.t_pred_q;
    $display("MODEL-01: %0d calibrated predictions within 1/256 of the exact product", checked);

    // ---- MODEL-02 ---------------------------------------------------------
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
    // raise engine 0 / SCALAR above unity: predicted 1, measured 1000
    update(3'd0, OPC_SCALAR, 32'd1000, 32'd1);
    rd_opclass = OPC_SCALAR; #1;
    k0 = rd_k[0];
    if (k0 <= 8'd64) begin errors++; $display("FAIL MODEL-02: setup could not raise k (k=%0d)", k0); end
    // A prediction whose calibrated value is just over 2^32 cycles, against
    // a measurement of 1024: the model was far too PESSIMISTIC, so k must go
    // DOWN. A 32-bit slice of the product wraps to under 4 and says up.
    tp = 32'((64'd1 << 38) / k0 + 1);
    update(3'd0, OPC_SCALAR, 32'd1024, tp);
    #1; k1 = rd_k[0];
    $display("MODEL-02: k=%0d, t_pred=%0d (calibrated about 2^32), measured 1024 -> k=%0d", k0, tp, k1);
    if (!(k1 < k0)) begin
      errors++; $display("FAIL MODEL-02: k moved the wrong way (%0d -> %0d): the comparison wrapped", k0, k1);
    end

    // An update with an index outside the table: nothing changes, nothing counted
    for (int c = 0; c < 9; c++) begin
      rd_opclass = opclass_e'(c); #1;
      for (int e = 0; e < ENG_N; e++) snap[e][c] = rd_k[e];
    end
    n0 = upd_count;
    update(3'd7, OPC_SCALAR, 32'd1000, 32'd1);          // engine 7 does not exist
    update(3'd0, opclass_e'(4'd15), 32'd1000, 32'd1);   // op class 15 does not exist
    for (int c = 0; c < 9; c++) begin
      rd_opclass = opclass_e'(c); #1;
      for (int e = 0; e < ENG_N; e++)
        if (rd_k[e] !== snap[e][c]) begin
          errors++; $display("FAIL MODEL-02: an out-of-range update changed k[%0d][%0d]", e, c);
        end
    end
    if (upd_count !== n0) begin
      errors++; $display("FAIL MODEL-02: an out-of-range update was counted (%0d -> %0d)", n0, upd_count);
    end

    if (errors) begin $display("FAIL tb_cost_cal: %0d errors", errors); $fatal(1); end
    $display("PASS tb_cost_cal: %0d cost products within 1/256 of exact; calibration compares without wrapping and ignores out-of-range updates", checked);
    $finish;
  end
endmodule
`default_nettype wire
