/*
 * tpu_drain.sv -- turn a row of accumulators into a 32-bit stream
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * The array hands over N results at once. Carrying N x 32 bits to the rest of
 * the chip would make the result bus the widest thing in the design for a
 * transfer that happens once per tile, so this serialises it: one result per
 * cycle, in row-major order, with a valid and a last.
 */
`default_nettype none
module tpu_drain
  import tpu_pkg::*;
#(
  parameter int unsigned N = N_PE
) (
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire                    row_valid,                 // a row arrived
  input  wire [N*ACCW-1:0]       row,                       // packed, lane 0 low
  input  wire                    row_last,                  // final row
  output logic                   res_valid,
  output logic signed [ACCW-1:0] res_data,
  output logic                   res_last,
  output logic                   busy                       // still emitting
);
  // Packed for the same reason the feeder is: a loop variable inside a
  // clocked block becomes a register after conversion and yosys rejects it.
  logic [N*ACCW-1:0]      buf_q;
  logic [$clog2(N+1)-1:0] idx_q;
  logic                   last_q, active_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idx_q <= '0; last_q <= 1'b0; active_q <= 1'b0; buf_q <= '0;
    end else if (row_valid && !active_q) begin
      buf_q <= row;
      idx_q <= '0; last_q <= row_last; active_q <= 1'b1;
    end else if (active_q) begin
      if (idx_q == ($clog2(N+1))'(N - 1)) active_q <= 1'b0;
      else                                 idx_q <= idx_q + 1'b1;
    end
  end

  assign res_valid = active_q;
  assign res_data  = buf_q[idx_q*ACCW +: ACCW];
  assign res_last  = active_q && last_q && (idx_q == ($clog2(N+1))'(N - 1));
  assign busy      = active_q;
endmodule
`default_nettype wire
