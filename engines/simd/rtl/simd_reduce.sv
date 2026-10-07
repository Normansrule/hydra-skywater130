/*
 * simd_reduce.sv -- sum across the lanes, and across the groups
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * A balanced adder over the lanes feeding one accumulator, so a reduction
 * of K groups costs K cycles rather than K*NLANE. The tree is written as a
 * loop over a packed vector for the same synthesis reason as simd_lanes.
 *
 * Wrapping is deliberate and documented: the accumulator is EW bits and a
 * long reduction can exceed it. Widening to 64 bits doubles the register
 * and still wraps eventually; saturating hides the overflow from software.
 * Wrapping at least matches what the model computes, so the two can be
 * compared exactly, and the width is a parameter when that changes.
 */
`default_nettype none
module simd_reduce
  import simd_pkg::*;
#(
  parameter int unsigned N = NLANE
) (
  input  wire              clk,
  input  wire              rst_n,
  input  wire              clr,          // start a new reduction
  input  wire              in_valid,
  input  wire  [N*EW-1:0]  y,
  output logic signed [EW-1:0] acc
);
  logic signed [EW-1:0] lane_sum;

  always_comb begin
    lane_sum = '0;
    for (int l = 0; l < N; l++) lane_sum = lane_sum + signed'(y[l*EW +: EW]);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)           acc <= '0;
    else if (clr)         acc <= '0;
    else if (in_valid)    acc <= acc + lane_sum;
  end
endmodule
`default_nettype wire
