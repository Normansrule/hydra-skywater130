/*
 * hydra_dma_agen.sv -- the address arithmetic, on its own
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Counters and adds, no handshakes and no state beyond the counter: the
 * piece that is easy to get wrong by one and easy to test alone.
 *
 * Operand layout, which is a CONTRACT with whoever fills the scratchpad:
 *   A bank, word k  = a[0..3][k]   one byte per lane, lane 0 in bits [7:0]
 *   B bank, word k  = b[k][0..3]
 * So one word from each bank is one complete slice for a 4-lane engine.
 * That layout is why the streamer needs no gather logic at all -- the cost
 * of the transpose was paid once, by whoever wrote A into the bank.
 */
`default_nettype none
module hydra_dma_agen #(
  parameter int unsigned AW   = 9,
  parameter int unsigned CNTW = 16
) (
  input  wire             clk,
  input  wire             rst_n,
  input  wire             load,          // latch the bases and clear
  input  wire [AW-1:0]    base_a,
  input  wire [AW-1:0]    base_b,
  input  wire [AW-1:0]    base_c,
  input  wire             step_rd,       // one operand slice consumed
  // Present the NEXT read address this cycle instead of the current one.
  // The bank reads every cycle, so its output register always holds the
  // word for the previous cycle's address: re-presenting the current
  // address keeps a fetched word alive through a stall, and presenting the
  // next one fetches ahead the moment the current word is taken.
  input  wire             peek,
  input  wire             step_wr,       // one result written
  output logic [AW-1:0]   addr_a,
  output logic [AW-1:0]   addr_b,
  output logic [AW-1:0]   addr_c,
  output logic [CNTW-1:0] rd_count,
  output logic [CNTW-1:0] wr_count
);
  logic [AW-1:0]   ba_q, bb_q, bc_q;
  logic [CNTW-1:0] rd_q, wr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ba_q <= '0; bb_q <= '0; bc_q <= '0; rd_q <= '0; wr_q <= '0;
    end else if (load) begin
      ba_q <= base_a; bb_q <= base_b; bc_q <= base_c;
      rd_q <= '0;     wr_q <= '0;
    end else begin
      if (step_rd) rd_q <= rd_q + CNTW'(1);
      if (step_wr) wr_q <= wr_q + CNTW'(1);
    end
  end

  assign addr_a   = ba_q + AW'(rd_q) + AW'(peek);
  assign addr_b   = bb_q + AW'(rd_q) + AW'(peek);
  assign addr_c   = bc_q + AW'(wr_q);
  assign rd_count = rd_q;
  assign wr_count = wr_q;
endmodule
`default_nettype wire
