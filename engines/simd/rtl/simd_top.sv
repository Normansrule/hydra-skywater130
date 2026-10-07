/*
 * simd_top.sv -- the SIMD unit as an engine the dispatcher can use
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Engine port in, operand groups in, results out -- the same shape as
 * tpu_top, deliberately.
 *
 * Descriptor fields, positions from mom_pkg's work_desc_t:
 *   [127:124] op_class   1 ELEMENT, 2 REDUCE, 0 SCALAR
 *   [123:121] dtype      2 = INT32 (this unit is 32-bit)
 *   [116:101] dim_m      ELEMENT COUNT, and it must be a multiple of NLANE
 *   [2:0]     lane opcode, in reserved bits -- see simd_pkg.sv
 *
 * The element count comes from dim_m, not dim_k, because that is what the
 * dispatcher's cost model already uses for this operation class: its work
 * volume for SCALAR, ELEMENT and REDUCE is W = M. Reading dim_k here while
 * the cost model read dim_m meant the dispatcher priced a four-element
 * vector and the engine ran sixteen -- so every cost estimate was wrong by
 * the lane count, and the calibration loop would have spent its life
 * correcting a units mismatch. Found by putting both engines behind the
 * real dispatcher and watching where the work went.
 *
 * A count that is not a multiple of NLANE is refused rather than padded:
 * padding invents operands, and the extra results would not match anything
 * software expects.
 */
`default_nettype none
module simd_top
  import simd_pkg::*;
#(
  parameter int unsigned N    = NLANE,
  parameter int unsigned WD_W = 128,
  parameter int unsigned TAGW = 4
) (
  input  wire                  clk,
  input  wire                  rst_n,

  input  wire                  eng_valid,
  output logic                 eng_ready,
  input  wire  [WD_W-1:0]      eng_wd,
  input  wire  [TAGW-1:0]      eng_tag,
  output logic                 eng_done,
  output logic [TAGW-1:0]      eng_done_tag,

  output logic                 op_ready,
  input  wire                  op_valid,
  input  wire  [N*EW-1:0]      op_a,
  input  wire  [N*EW-1:0]      op_b,

  output logic                 res_valid,
  output logic signed [EW-1:0] res_data,
  output logic                 res_last,

  output simd_status_e         status
);
  localparam logic [3:0] OPC_SCALAR_C  = 4'd0;
  localparam logic [3:0] OPC_ELEMENT_C = 4'd1;
  localparam logic [3:0] OPC_REDUCE_C  = 4'd2;
  localparam logic [2:0] DT_INT32_C    = 3'd2;

  wire [3:0]      wd_opclass = eng_wd[127:124];
  wire [2:0]      wd_dtype   = eng_wd[123:121];
  wire [CNTW-1:0] wd_m       = eng_wd[116:101];
  // groups = elements / NLANE, and zero (which the controller reports as a
  // dimension error) when the count is not a whole number of groups.
  wire            m_aligned  = (wd_m[$clog2(N)-1:0] == '0) && (wd_m != '0);
  wire [CNTW-1:0] wd_groups  = m_aligned ? (wd_m >> $clog2(N)) : '0;
  wire simd_op_e  wd_op      = simd_op_e'(eng_wd[2:0]);

  wire accept = eng_valid && eng_ready;

  logic [TAGW-1:0] tag_q;
  simd_op_e        op_q;
  logic            reduce_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tag_q <= '0; op_q <= SOP_ADD; reduce_q <= 1'b0;
    end else if (accept) begin
      tag_q    <= eng_tag;
      op_q     <= wd_op;
      reduce_q <= (wd_opclass == OPC_REDUCE_C);
    end
  end

  wire            lanes_valid, acc_clr, emit_group, emit_last;
  wire            serial_busy, lanes_out_valid, ctrl_busy, ctrl_done;
  wire [N*EW-1:0] lanes_y;
  wire signed [EW-1:0] acc;

  simd_ctrl #(.N(N)) u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .start(accept), .dim_k(wd_groups),
    .opclass_ok((wd_opclass == OPC_ELEMENT_C) || (wd_opclass == OPC_REDUCE_C) ||
                (wd_opclass == OPC_SCALAR_C)),
    .is_reduce(wd_opclass == OPC_REDUCE_C),
    .dtype_ok(wd_dtype == DT_INT32_C),
    .op_ready(op_ready), .op_valid(op_valid),
    .lanes_valid(lanes_valid), .acc_clr(acc_clr),
    .emit_group(emit_group), .emit_last(emit_last),
    .serial_busy(serial_busy), .lanes_out_valid(lanes_out_valid),
    .done(ctrl_done), .status(status), .busy(ctrl_busy));

  simd_lanes #(.N(N)) u_lanes (
    .clk(clk), .rst_n(rst_n), .in_valid(lanes_valid), .op(op_q),
    .a(op_a), .b(op_b), .out_valid(lanes_out_valid), .y(lanes_y));

  simd_reduce #(.N(N)) u_reduce (
    .clk(clk), .rst_n(rst_n), .clr(acc_clr),
    .in_valid(lanes_out_valid && reduce_q), .y(lanes_y), .acc(acc));

  // A reduction produces ONE result, so it bypasses the lane serialiser and
  // is presented directly. Two paths into one port, never both at once:
  // emit_group is gated on !reduce_q in the controller.
  wire                 ser_valid;
  wire signed [EW-1:0] ser_data;
  wire                 ser_last;

  simd_serial #(.N(N)) u_ser (
    .clk(clk), .rst_n(rst_n),
    .in_valid(emit_group), .y(lanes_y), .in_last(emit_last),
    .res_valid(ser_valid), .res_data(ser_data), .res_last(ser_last),
    .busy(serial_busy));

  wire reduce_emit = reduce_q && ctrl_done;

  assign res_valid    = reduce_emit ? 1'b1 : ser_valid;
  assign res_data     = reduce_emit ? acc  : ser_data;
  assign res_last     = reduce_emit ? 1'b1 : ser_last;
  assign eng_ready    = !ctrl_busy;
  assign eng_done     = ctrl_done;
  assign eng_done_tag = tag_q;
endmodule
`default_nettype wire
