/*
 * tpu_feeder.sv -- diagonal skew of the operand slices
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * A systolic array only computes the right thing if operands ARRIVE at the
 * right time: element k of row i must reach processing element (i, *) at
 * cycle k + i, because that is when the b value it must meet gets there.
 *
 * So the feeder delays lane i by i cycles, for both operands. It is a
 * triangle of shift registers and nothing else, which is why it is its own
 * file: it is the part that is easy to get wrong and easy to test alone.
 */
`default_nettype none
module tpu_feeder
  import tpu_pkg::*;
#(
  parameter int unsigned N = N_PE
) (
  input  wire                   clk,
  input  wire                   rst_n,
  input  wire                   flush,             // drop everything in flight
  input  wire                   step,              // advance the pipeline
  input  wire                   in_valid,          // inject a real slice
  input  wire signed [AW-1:0]   a_slice [N],       // a[i][k] for every i
  input  wire signed [AW-1:0]   b_slice [N],       // b[k][j] for every j
  output logic signed [AW-1:0]  a_skew  [N],       // lane i delayed by i
  output logic signed [AW-1:0]  b_skew  [N]
);
  // Lane 0 is combinational (delay zero); lane i owns i registers.
  genvar i;
  generate
    for (i = 0; i < N; i++) begin : g_lane
      if (i == 0) begin : g_direct
        assign a_skew[0] = in_valid ? a_slice[0] : '0;
        assign b_skew[0] = in_valid ? b_slice[0] : '0;
      end else begin : g_delay
        // A packed vector, not an unpacked array with a loop: sv2v turns a
        // loop variable inside a clocked block into a register of its own,
        // and yosys then refuses the module with "multiple edge sensitive
        // events". Simulation never noticed. Shifting a packed vector is
        // also literally what the hardware is.
        logic [i*AW-1:0] a_pipe, b_pipe;
        // `flush` is SYNCHRONOUS and must not share the asynchronous reset
        // branch. Writing `if (!rst_n || flush)` simulates correctly in
        // Icarus and is rejected by yosys ("multiple edge sensitive events"),
        // which is the good outcome -- the bad one is a tool that accepts it
        // and infers a second asynchronous reset on the flush net.
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            a_pipe <= '0;
            b_pipe <= '0;
          end else if (flush) begin
            a_pipe <= '0;
            b_pipe <= '0;
          end else if (step) begin
            a_pipe <= {a_pipe[(i-1)*AW-1:0], (in_valid ? a_slice[i] : {AW{1'b0}})};
            b_pipe <= {b_pipe[(i-1)*AW-1:0], (in_valid ? b_slice[i] : {AW{1'b0}})};
          end
        end
        assign a_skew[i] = a_pipe[i*AW-1 -: AW];
        assign b_skew[i] = b_pipe[i*AW-1 -: AW];
      end
    end
  endgenerate
endmodule
`default_nettype wire
