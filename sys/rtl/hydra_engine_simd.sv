/*
 * hydra_engine_simd.sv -- the real vector unit behind the engine port
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Same arrangement as hydra_engine_tpu: the engine is real, the operands
 * come from a pattern generator standing in for the direct memory access
 * engine that does not exist yet, and a position-sensitive checksum makes
 * the results observable without a wide result bus.
 *
 *   a[lane] = 0x01010101 * (lane + 1) + group
 *   b[lane] = 0x00010001 * (lane + 2) + (group << 3)
 *
 * Reproduced in sys/tb/simd_pattern_model.py.
 */
`default_nettype none
module hydra_engine_simd
  import simd_pkg::*;
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
  output logic [31:0]      checksum,
  output logic [15:0]      jobs_done,
  output simd_status_e     last_status
);
  logic [CNTW-1:0]  grp_q;
  logic [N*EW-1:0]  op_a, op_b;
  wire              op_ready;
  wire              op_valid = 1'b1;

  always_comb begin
    for (int l = 0; l < N; l++) begin
      op_a[l*EW +: EW] = (32'h0101_0101 * 32'(l + 1)) + 32'(grp_q);
      op_b[l*EW +: EW] = (32'h0001_0001 * 32'(l + 2)) + (32'(grp_q) << 3);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                      grp_q <= '0;
    else if (eng_valid && eng_ready) grp_q <= '0;
    else if (op_valid && op_ready)   grp_q <= grp_q + CNTW'(1);
  end

  wire                 res_valid, res_last;
  wire signed [EW-1:0] res_data;

  simd_top #(.N(N), .WD_W(WD_W), .TAGW(TAGW)) u_simd (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .op_ready(op_ready), .op_valid(op_valid), .op_a(op_a), .op_b(op_b),
    .res_valid(res_valid), .res_data(res_data), .res_last(res_last),
    .status(last_status));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      checksum <= '0; jobs_done <= '0;
    end else begin
      if (res_valid) checksum <= {checksum[30:0], checksum[31]} ^ res_data;
      if (eng_done)  jobs_done <= jobs_done + 16'd1;
    end
  end

  wire _unused = &{res_last, 1'b0};
endmodule
`default_nettype wire
