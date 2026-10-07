/*
 * tpu_array.sv -- the N x N grid
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Wiring only: operands flow left-to-right and top-to-bottom, accumulators
 * shift downwards during drain, and the bottom row is the output. No control
 * lives here -- tpu_ctrl decides when each of those happens.
 */
`default_nettype none
module tpu_array
  import tpu_pkg::*;
#(
  parameter int unsigned N = N_PE
) (
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire                    en,
  input  wire                    clr,
  input  wire                    shift_en,
  input  wire signed [AW-1:0]    a_west  [N],      // one per row
  input  wire signed [AW-1:0]    b_north [N],      // one per column
  output logic signed [ACCW-1:0] acc_south [N]     // bottom row, during drain
);
  logic signed [AW-1:0]   a_h [N][N+1];
  logic signed [AW-1:0]   b_v [N+1][N];
  logic signed [ACCW-1:0] acc_v [N+1][N];

  genvar r, c;
  generate
    for (r = 0; r < N; r++) begin : g_west
      assign a_h[r][0] = a_west[r];
    end
    for (c = 0; c < N; c++) begin : g_north
      assign b_v[0][c]   = b_north[c];
      // Nothing shifts into the top row: it clears as the column drains.
      assign acc_v[0][c] = '0;
    end
    for (r = 0; r < N; r++) begin : g_row
      for (c = 0; c < N; c++) begin : g_col
        tpu_pe u_pe (
          .clk(clk), .rst_n(rst_n), .en(en), .clr(clr), .shift_en(shift_en),
          .a_in(a_h[r][c]), .b_in(b_v[r][c]), .acc_in(acc_v[r][c]),
          .a_out(a_h[r][c+1]), .b_out(b_v[r+1][c]), .acc_out(acc_v[r+1][c]));
      end
    end
    for (c = 0; c < N; c++) begin : g_south
      assign acc_south[c] = acc_v[N][c];
    end
  endgenerate
endmodule
`default_nettype wire
