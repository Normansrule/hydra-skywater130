/*
 * hydra_spram.sv -- single-port synchronous scratchpad bank
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * One write port and one read port sharing an address, registered read,
 * inferred rather than instantiated so the same file targets an FPGA block
 * memory and a sky130 macro (or a register file, at small depths) without
 * a vendor primitive in the source.
 *
 * Read-during-write returns the OLD contents. That is stated because the
 * two behaviours differ between technologies and code that relies on the
 * new value works on one and fails silently on the other; nothing in this
 * design reads an address it is writing in the same cycle, and
 * tb_hydra_dma checks that the streamer never does.
 */
`default_nettype none
module hydra_spram #(
  parameter int unsigned DW    = 32,
  parameter int unsigned DEPTH = 512,
  parameter int unsigned AW    = $clog2(DEPTH)
) (
  input  wire           clk,
  input  wire           we,
  input  wire [AW-1:0]  addr,
  input  wire [DW-1:0]  wdata,
  output logic [DW-1:0] rdata
);
  logic [DW-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (we) mem[addr] <= wdata;
    rdata <= mem[addr];        // old contents on a write: see the header
  end
endmodule
`default_nettype wire
