/*
 * ntt_butterfly.sv -- one Cooley-Tukey butterfly over GF(q)
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 *   v = b * w mod q
 *   y0 = (a + v) mod q
 *   y1 = (a - v) mod q
 *
 * Add and subtract are single conditional corrections because both inputs
 * are already reduced: a + v < 2q, and a - v + q < 2q. Inputs that are NOT
 * reduced would silently produce garbage, so the controller refuses them
 * -- see ntt_ctrl. Registered outputs; the multiply is the long path.
 */
`default_nettype none
module ntt_butterfly
  import ntt_pkg::*;
(
  input  wire              clk,
  input  wire              rst_n,
  input  wire              in_valid,
  input  wire  [QW-1:0]    a,
  input  wire  [QW-1:0]    b,
  input  wire  [QW-1:0]    w,
  output logic             out_valid,
  output logic [QW-1:0]    y0,
  output logic [QW-1:0]    y1
);
  wire [QW-1:0] v;
  ntt_modmul u_mul (.a(b), .b(w), .y(v));

  wire [QW:0] sum  = a + v;
  wire [QW:0] diff = a + Q[QW:0] - v;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      y0 <= '0; y1 <= '0; out_valid <= 1'b0;
    end else begin
      y0        <= (sum  >= Q[QW:0]) ? (sum  - Q[QW:0]) : sum[QW-1:0];
      y1        <= (diff >= Q[QW:0]) ? (diff - Q[QW:0]) : diff[QW-1:0];
      out_valid <= in_valid;
    end
  end
endmodule
`default_nettype wire
