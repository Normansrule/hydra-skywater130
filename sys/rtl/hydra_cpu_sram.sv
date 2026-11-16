/*
 * hydra_cpu_sram.sv -- the CPU's main memory in SkyWater 130 SRAM macros
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY
 * ===========================================================================
 * Behind Sixfold's two caches, main memory has one write port (the stores,
 * write-through) and two line read ports (instruction and data refills).
 * Sixfold's FPGA MainMemory builds that from block RAM. A chip cannot: 64 KiB
 * of flip-flops would be most of the die. This module builds the same
 * interface, cycle for cycle, from OpenRAM macros in the SkyWater 130 PDK
 * (sky130_sram_2kbyte_1rw1r_32x512_8: 512 words of 32 bits, one read/write
 * port and one read-only port, 683 x 417 um).
 *
 * ===========================================================================
 * ORGANISATION
 * ===========================================================================
 * A cache line is 8 words of 32 bits. Word w of every line lives in lane w:
 * eight lanes, each LINES words deep, made of LINES/512 macros. So 512 lines
 * (16 KiB) take 8 macros, 2048 lines (64 KiB) take 32.
 *
 *   port 1 (read only)   the instruction refill, read every cycle
 *   port 0 (read/write)  the store when there is one; otherwise the data
 *                        refill (or the host's read when the core is idle)
 *
 * Address bits above the line index are ignored: a 16 KiB memory appears
 * four times in the core's 64 KiB space. Software must keep its code, data
 * and stack inside one copy (docs/architecture/microcontroller.md).
 *
 * ===========================================================================
 * TIMING CONTRACT (the same as MainMemory, checked by make cpu-sram)
 * ===========================================================================
 * A line read with its address in cycle T-1 is returned in cycle T, and it
 * includes a store made in cycle T-1 (the store is merged in, "bypass"). On
 * port 0 a lane that is being written cannot be read in that cycle, so each
 * lane keeps the last word it returned, with any store to that line merged
 * into it, and returns that instead. That is exact as long as the data
 * refill address does not change in a cycle in which a store writes the
 * same lane. Sixfold cannot do both in one cycle, because a store and a load
 * miss would both have to be in the memory stage. The simulation build
 * reports it if it ever happens.
 * ===========================================================================
 */
`default_nettype none

module hydra_cpu_sram #(
  parameter int LINES  = 512,        // 512 (16 KiB, 8 macros) .. 2048 (64 KiB, 32 macros)
  parameter bit MACROS = 1'b1        // 1: OpenRAM macros; 0: an equivalent model (FPGA, lint)
) (
  input  wire          clk,
  input  wire  [15:0]  WRITE_ADDRESS,                 // byte address of the doubleword
  input  wire  [7:0]   WRITE_MASK,                    // byte lanes, 0 = no store
  input  wire  [63:0]  WRITE_DATA,
  input  wire  [15:0]  INSTRUCTION_REFILL_ADDRESS,
  output logic [255:0] INSTRUCTION_REFILL_LINE,
  input  wire  [15:0]  DATA_REFILL_ADDRESS,
  output logic [255:0] DATA_REFILL_LINE,
  input  wire          check_en          // the core is running: the contract applies
);
  localparam int IB = $clog2(LINES);      // line index bits
  localparam int NB = LINES / 512;        // macros per lane
  localparam int BB = (NB > 1) ? $clog2(NB) : 1;

  wire [IB-1:0] w_idx = WRITE_ADDRESS[IB+4:5];
  wire [IB-1:0] i_idx = INSTRUCTION_REFILL_ADDRESS[IB+4:5];
  wire [IB-1:0] d_idx = DATA_REFILL_ADDRESS[IB+4:5];
  wire [1:0]    w_dw  = WRITE_ADDRESS[4:3];               // which doubleword of the line

  // per lane: the store's 4 byte enables and data
  logic [3:0]  lane_we   [8];
  logic [31:0] lane_wdat [8];
  always_comb
    for (int l = 0; l < 8; l++) begin
      lane_we[l]   = (l / 2 == int'(w_dw)) ? ((l % 2 == 1) ? WRITE_MASK[7:4] : WRITE_MASK[3:0]) : 4'd0;
      lane_wdat[l] = (l % 2 == 1) ? WRITE_DATA[63:32] : WRITE_DATA[31:0];
    end

  // the last store, for the port-1 bypass
  logic [IB-1:0] last_idx;
  logic [3:0]    last_we   [8];
  logic [31:0]  last_wdat [8];
  logic [IB-1:0] i_idx_q, d_idx_q;
  always_ff @(posedge clk) begin
    last_idx <= w_idx; i_idx_q <= i_idx; d_idx_q <= d_idx;
    for (int l = 0; l < 8; l++) begin last_we[l] <= lane_we[l]; last_wdat[l] <= lane_wdat[l]; end
  end

  function automatic logic [31:0] merge(input logic [31:0] old, input logic [3:0] we, input logic [31:0] d);
    for (int b = 0; b < 4; b++) merge[8*b +: 8] = we[b] ? d[8*b +: 8] : old[8*b +: 8];
  endfunction

  // the byte within a doubleword (stores) or line (refills), and the address
  // bits above this memory: it repeats through the 64 KiB space
  wire _unused_addr = &{1'b0, WRITE_ADDRESS, INSTRUCTION_REFILL_ADDRESS, DATA_REFILL_ADDRESS};

  genvar L, B;
  generate
    for (L = 0; L < 8; L++) begin : g_lane
      wire        writing = |lane_we[L];
      logic       rd0_q;                      // port 0 read this lane last cycle
      logic [31:0] held_q;
      wire [31:0] p0_word, p1_word;
      wire [31:0] p0_dout [NB];
      wire [31:0] p1_dout [NB];

      for (B = 0; B < NB; B++) begin : g_bank
        wire        sel_w = (NB == 1) || (w_idx[IB-1 -: BB] == BB'(B));
        wire        sel_d = (NB == 1) || (d_idx[IB-1 -: BB] == BB'(B));
        wire        sel_i = (NB == 1) || (i_idx[IB-1 -: BB] == BB'(B));
        wire        csb0  = !(writing ? sel_w : sel_d);
        wire        web0  = !writing;
        wire [8:0]  addr0 = writing ? w_idx[8:0] : d_idx[8:0];
        wire        csb1  = !sel_i;
        if (MACROS) begin : g_macro
`ifdef SYNTHESIS
          sky130_sram_2kbyte_1rw1r_32x512_8 u_ram (     // a black box: the macro has no parameters
`else
          sky130_sram_2kbyte_1rw1r_32x512_8 #(.VERBOSE(0)) u_ram (   // the PDK model, quiet
`endif
            .clk0(clk), .csb0(csb0), .web0(web0), .wmask0(lane_we[L]), .addr0(addr0),
            .din0(lane_wdat[L]), .dout0(p0_dout[B]),
            .clk1(clk), .csb1(csb1), .addr1(i_idx[8:0]), .dout1(p1_dout[B]));
        end else begin : g_model
          hydra_sram_1rw1r_512x32 u_ram (
            .clk(clk), .csb0(csb0), .web0(web0), .wmask0(lane_we[L]), .addr0(addr0),
            .din0(lane_wdat[L]), .dout0(p0_dout[B]),
            .csb1(csb1), .addr1(i_idx[8:0]), .dout1(p1_dout[B]));
        end
      end

      if (NB == 1) begin : g_one
        assign p0_word = p0_dout[0];
        assign p1_word = p1_dout[0];
      end else begin : g_many
        assign p0_word = p0_dout[d_idx_q[IB-1 -: BB]];
        assign p1_word = p1_dout[i_idx_q[IB-1 -: BB]];
      end

      // port 1: the read, with the last store merged in when it hit this line
      assign INSTRUCTION_REFILL_LINE[32*L +: 32] =
        (i_idx_q == last_idx) ? merge(p1_word, last_we[L], last_wdat[L]) : p1_word;

      // port 0: the read when there was one, otherwise the held word
      wire [31:0] d_word = rd0_q ? p0_word : held_q;
      assign DATA_REFILL_LINE[32*L +: 32] = d_word;
      always_ff @(posedge clk) begin
        rd0_q  <= !writing;
        held_q <= (writing && w_idx == d_idx) ? merge(d_word, lane_we[L], lane_wdat[L]) : d_word;
      end

`ifndef SYNTHESIS
      // the one case the held word cannot cover (see the header)
      always @(posedge clk)
        if (check_en && writing && d_idx != d_idx_q)
          $display("FAIL hydra_cpu_sram: lane %0d written while the data refill address moved, at %0t", L, $time);
`endif
    end
  endgenerate

endmodule

// An equivalent of the OpenRAM macro's behaviour at the clock edge, for the
// FPGA images and for Verilator: synchronous write with byte enables on port
// 0, a registered read on each port. (The macro reads half a cycle after the
// edge; at the next rising edge both give the same word.)
module hydra_sram_1rw1r_512x32 (
  input  wire        clk,
  input  wire        csb0,
  input  wire        web0,
  input  wire [3:0]  wmask0,
  input  wire [8:0]  addr0,
  input  wire [31:0] din0,
  output logic [31:0] dout0,
  input  wire        csb1,
  input  wire [8:0]  addr1,
  output logic [31:0] dout1
);
  logic [31:0] mem [512];
  always_ff @(posedge clk) begin
    if (!csb0 && !web0)
      for (int b = 0; b < 4; b++) if (wmask0[b]) mem[addr0][8*b +: 8] <= din0[8*b +: 8];
    if (!csb0 && web0) dout0 <= mem[addr0];
    if (!csb1)         dout1 <= mem[addr1];
  end
endmodule

`default_nettype wire
