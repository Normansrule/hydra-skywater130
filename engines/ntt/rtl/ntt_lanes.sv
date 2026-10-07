/*
 * ntt_lanes.sv -- NLANE butterflies side by side
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Wiring only. Packed vectors rather than unpacked arrays, for the
 * synthesis reason recorded in simd_lanes.sv and tpu_drain.sv.
 */
`default_nettype none
module ntt_lanes
  import ntt_pkg::*;
#(
  parameter int unsigned N = NLANE
) (
  input  wire              clk,
  input  wire              rst_n,
  input  wire              in_valid,
  input  wire  [N*QW-1:0]  a,
  input  wire  [N*QW-1:0]  b,
  input  wire  [N*QW-1:0]  w,
  output logic             out_valid,
  output logic [N*QW-1:0]  y0,
  output logic [N*QW-1:0]  y1
);
  wire [N-1:0] lane_valid;

  genvar l;
  generate
    for (l = 0; l < N; l++) begin : g_bfly
      ntt_butterfly u_bf (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .a(a[l*QW +: QW]), .b(b[l*QW +: QW]), .w(w[l*QW +: QW]),
        .out_valid(lane_valid[l]),
        .y0(y0[l*QW +: QW]), .y1(y1[l*QW +: QW]));
    end
  endgenerate

  assign out_valid = lane_valid[0];   // all lanes share a pipeline depth
endmodule
`default_nettype wire
