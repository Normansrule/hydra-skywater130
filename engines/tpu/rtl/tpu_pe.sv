/*
 * tpu_pe.sv -- one processing element
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Multiply-accumulate with two jobs and no third:
 *   compute   acc += a * b, and pass a to the right, b downwards
 *   drain     acc <= the accumulator above, so a column shifts out
 *
 * `clr` is separate from reset because a tile boundary is not a reset: the
 * pipeline registers keep flowing while the accumulator restarts.
 */
`default_nettype none
module tpu_pe
  import tpu_pkg::*;
(
  input  wire                     clk,
  input  wire                     rst_n,
  input  wire                     en,        // accumulate this cycle
  input  wire                     clr,       // start a new tile
  input  wire                     shift_en,  // drain: take the value above
  input  wire signed [AW-1:0]     a_in,
  input  wire signed [AW-1:0]     b_in,
  input  wire signed [ACCW-1:0]   acc_in,
  output logic signed [AW-1:0]    a_out,
  output logic signed [AW-1:0]    b_out,
  output logic signed [ACCW-1:0]  acc_out
);
  logic signed [ACCW-1:0] acc_q;
  wire  signed [2*AW-1:0] prod = a_in * b_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0; b_out <= '0; acc_q <= '0;
    end else begin
      // The operand registers advance only when the array steps, for the
      // same reason the feeder does: a stalled cycle must freeze the whole
      // systolic pipeline, not slide it forward with nothing behind it.
      if (en) begin
        a_out <= a_in;
        b_out <= b_in;
      end
      // Priority matters: clear beats drain beats accumulate. A tile start
      // arriving during a drain must win, or the first slice of the next
      // matrix lands on top of the previous result.
      if (clr)            acc_q <= '0;
      else if (shift_en)  acc_q <= acc_in;
      else if (en)        acc_q <= acc_q + ACCW'(prod);
    end
  end

  assign acc_out = acc_q;
endmodule
`default_nettype wire
