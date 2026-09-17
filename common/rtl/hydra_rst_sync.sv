// =============================================================================
// hydra_rst_sync.sv -- asynchronous assert, synchronous release
// =============================================================================
// WHY: every generated top (TT tile, OpenFrame, FPGA board) receives reset
// from a different place -- rst_n from the TT mux, a pad plus POR in
// OpenFrame, a push button plus PLL lock on an FPGA. All of them are
// asynchronous to the core clock. Releasing reset asynchronously lets
// different flops leave reset on different edges; that is a classic
// works-in-simulation, fails-on-silicon bug, which this project cannot afford.
//
// scan_mode bypasses the synchroniser so ATPG controls reset directly from
// scan_rst_n. Tie scan_mode low where there is no scan chain (FPGA, TT).
// =============================================================================
`default_nettype none

module hydra_rst_sync #(
  parameter int STAGES = 2
) (
  input  logic clk,
  input  logic arst_n,       // asynchronous, active low (AND of all sources)
  input  logic scan_mode,
  input  logic scan_rst_n,
  output logic rst_n         // async assert, sync release
);
  logic [STAGES-1:0] sync_q;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) sync_q <= '0;
    else         sync_q <= {sync_q[STAGES-2:0], 1'b1};
  end

  assign rst_n = scan_mode ? scan_rst_n : sync_q[STAGES-1];

`ifdef FORMAL
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;
  always_comb if (!past_valid) assume (!arst_n);
  always_comb assume (!scan_mode);
  // Assert is immediate.
  always_comb if (!arst_n) assert (!rst_n);
  // Release only after STAGES clean edges.
  logic [7:0] clean;
  always_ff @(posedge clk or negedge arst_n)
    if (!arst_n) clean <= 0; else if (clean != 8'hff) clean <= clean + 1;
  always_comb if (rst_n) assert (clean >= STAGES);
  always_ff @(posedge clk) if (past_valid) cover (rst_n);
`endif
endmodule

`default_nettype wire
