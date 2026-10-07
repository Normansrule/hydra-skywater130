/*
 * simd_alu.sv -- one lane's arithmetic
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Combinational and nothing else: the pipeline registers live in
 * simd_lanes, so this file can be read, reviewed and exhaustively tested as
 * a pure function of (op, a, b).
 *
 * MUL keeps the low 32 bits of the signed product, which is what a 32-bit
 * vector multiply means everywhere else and what the model computes. The
 * high half is discarded rather than saturated: silently saturating would
 * make the result depend on operand magnitude in a way software cannot see.
 */
`default_nettype none
module simd_alu
  import simd_pkg::*;
(
  input  wire  simd_op_e            op,
  input  wire  signed [EW-1:0]      a,
  input  wire  signed [EW-1:0]      b,
  output logic signed [EW-1:0]      y
);
  wire signed [2*EW-1:0] prod = a * b;

  always_comb begin
    unique case (op)
      SOP_ADD: y = a + b;
      SOP_SUB: y = a - b;
      SOP_MUL: y = prod[EW-1:0];
      SOP_MAX: y = (a > b) ? a : b;
      SOP_MIN: y = (a < b) ? a : b;
      SOP_AND: y = a & b;
      SOP_OR:  y = a | b;
      SOP_XOR: y = a ^ b;
      default: y = '0;
    endcase
  end
endmodule
`default_nettype wire
