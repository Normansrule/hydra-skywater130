/*
 * simd_lanes.sv -- NLANE copies of the arithmetic, registered
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * One pipeline stage: operands in, results out a cycle later, with a valid
 * that follows them. Vectors are packed rather than unpacked arrays -- a
 * loop variable inside a clocked block becomes a register after conversion
 * and yosys then rejects the module, which cost a synthesis run on the TPU.
 */
`default_nettype none
module simd_lanes
  import simd_pkg::*;
#(
  parameter int unsigned N = NLANE
) (
  input  wire                  clk,
  input  wire                  rst_n,
  input  wire                  in_valid,
  input  wire  simd_op_e       op,
  input  wire  [N*EW-1:0]      a,
  input  wire  [N*EW-1:0]      b,
  output logic                 out_valid,
  output logic [N*EW-1:0]      y
);
  wire [N*EW-1:0] y_comb;

  genvar l;
  generate
    for (l = 0; l < N; l++) begin : g_lane
      simd_alu u_alu (
        .op(op),
        .a(a[l*EW +: EW]),
        .b(b[l*EW +: EW]),
        .y(y_comb[l*EW +: EW]));
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      y         <= '0;
      out_valid <= 1'b0;
    end else begin
      y         <= y_comb;
      out_valid <= in_valid;
    end
  end
endmodule
`default_nettype wire
