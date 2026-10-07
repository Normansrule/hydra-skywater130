/*
 * ntt_top.sv -- the butterfly engine on the dispatcher's engine port
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Descriptor fields (positions from mom_pkg's work_desc_t):
 *   [127:124] op_class  6 = NTT
 *   [123:121] dtype     5 = POLY_Q
 *   [116:101] dim_m     coefficient pairs; must be a multiple of NLANE
 *
 * The element count is dim_m, matching what the dispatcher's cost model
 * prices -- the units mismatch found on the vector unit is not repeated
 * here, and tb_ntt checks the refusal for a count that is not a whole
 * number of groups.
 */
`default_nettype none
module ntt_top
  import ntt_pkg::*;
#(
  parameter int unsigned N    = NLANE,
  parameter int unsigned WD_W = 128,
  parameter int unsigned TAGW = 4
) (
  input  wire              clk,
  input  wire              rst_n,
  input  wire              eng_valid,
  output logic             eng_ready,
  input  wire [WD_W-1:0]   eng_wd,
  input  wire [TAGW-1:0]   eng_tag,
  output logic             eng_done,
  output logic [TAGW-1:0]  eng_done_tag,

  output logic             op_ready,
  input  wire              op_valid,
  input  wire [N*QW-1:0]   op_a,
  input  wire [N*QW-1:0]   op_b,
  input  wire [N*QW-1:0]   op_w,

  output logic             res_valid,
  output logic [N*QW-1:0]  res_y0,
  output logic [N*QW-1:0]  res_y1,
  output ntt_status_e      status
);
  localparam logic [3:0] OPC_NTT_C   = 4'd6;
  localparam logic [2:0] DT_POLY_Q_C = 3'd5;

  wire [3:0]      wd_opclass = eng_wd[127:124];
  wire [2:0]      wd_dtype   = eng_wd[123:121];
  wire [CNTW-1:0] wd_m       = eng_wd[116:101];
  wire            m_aligned  = (wd_m[$clog2(N)-1:0] == '0) && (wd_m != '0);
  wire [CNTW-1:0] wd_groups  = m_aligned ? (wd_m >> $clog2(N)) : '0;

  wire accept = eng_valid && eng_ready;
  logic [TAGW-1:0] tag_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     tag_q <= '0;
    else if (accept) tag_q <= eng_tag;
  end

  wire lanes_valid, lanes_out_valid, ctrl_busy, ctrl_done;

  ntt_ctrl u_ctrl (
    .clk(clk), .rst_n(rst_n), .start(accept), .dim_k(wd_groups),
    .opclass_ok(wd_opclass == OPC_NTT_C),
    .dtype_ok(wd_dtype == DT_POLY_Q_C),
    .op_ready(op_ready), .op_valid(op_valid),
    .lanes_valid(lanes_valid), .lanes_out_valid(lanes_out_valid),
    .done(ctrl_done), .status(status), .busy(ctrl_busy));

  ntt_lanes #(.N(N)) u_lanes (
    .clk(clk), .rst_n(rst_n), .in_valid(lanes_valid),
    .a(op_a), .b(op_b), .w(op_w),
    .out_valid(lanes_out_valid), .y0(res_y0), .y1(res_y1));

  assign res_valid    = lanes_out_valid;
  assign eng_ready    = !ctrl_busy;
  assign eng_done     = ctrl_done;
  assign eng_done_tag = tag_q;
endmodule
`default_nettype wire
