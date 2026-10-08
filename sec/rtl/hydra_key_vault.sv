/*
 * hydra_key_vault.sv -- keys the processor can write and use, but never read
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * THE ONE PROPERTY THAT MATTERS
 * ===========================================================================
 * Software loads a key into a slot and afterwards refers to it by SLOT
 * NUMBER. It can ask an engine to use slot 2; it cannot ask what is in slot
 * 2. This is the discipline Caliptra's key vault enforces, and it is the
 * reason a root of trust is worth building at all: an attacker who takes
 * over the processor still cannot walk away with the key.
 *
 * "The read port does not return key bits" is easy to believe and easy to
 * get wrong -- a debug register, a status field that accidentally muxes the
 * wrong word, a lazy `rdata <= mem[sel]`. So it is not believed here, it is
 * PROVED, by non-interference: two copies of this module are driven with
 * identical control and DIFFERENT key material, and the proof shows their
 * host-visible outputs are identical at every cycle. If any key bit reached
 * the host read port by any path, the two copies would diverge.
 * See sec/formal/key_vault_ni.sv.
 *
 * ===========================================================================
 * WHAT IT DOES AND DOES NOT PROTECT
 * ===========================================================================
 * It protects against software reading a key back through this interface.
 *
 * It does NOT protect against: power or timing analysis of the engine that
 * uses the key, an attacker with the scan chain (scan insertion must
 * exclude this storage or the whole exercise is theatre), fault injection,
 * or a physical attacker with the die. Those need countermeasures this
 * module does not have, and claiming otherwise would be worse than not
 * building it.
 *
 * Slots are volatile: they clear on reset and there is no non-volatile key
 * storage on this chip. Fuses or one-time-programmable memory are a
 * process-dependent macro, not something synthesisable from standard cells.
 */
`default_nettype none

module hydra_key_vault #(
  parameter int unsigned NSLOT = 4,        // key slots
  parameter int unsigned KW    = 256,      // bits per key
  parameter int unsigned WW    = 32        // bits per write
) (
  input  wire                          clk,
  input  wire                          rst_n,

  // ---- host side: write and control, never read key material -------------
  input  wire                          host_we,
  input  wire [$clog2(NSLOT)-1:0]      host_slot,
  input  wire [$clog2(KW/WW)-1:0]      host_word,
  input  wire [WW-1:0]                 host_wdata,
  input  wire                          host_lock,     // seal the slot
  input  wire                          host_wipe,     // clear every slot

  // Status only. Everything here is derived from metadata; no expression in
  // this module lets a key bit reach it.
  input  wire [$clog2(NSLOT)-1:0]      host_rd_slot,
  output logic [WW-1:0]                host_rdata,
  output logic                         err_locked,    // write to a sealed slot

  // ---- engine side: use, by slot number ----------------------------------
  input  wire                          eng_req,
  input  wire [$clog2(NSLOT)-1:0]      eng_slot,
  output logic [KW-1:0]                eng_key,
  output logic                         eng_valid
`ifdef FORMAL
  // Proof-only view of the vault's bookkeeping, as PORTS. The unbounded
  // non-interference proof has to state that two copies' bookkeeping stays
  // identical; hierarchical references into the copies did not survive
  // conversion to Verilog, ports do. Absent from every non-formal build.
  ,
  output logic [NSLOT-1:0]             f_locked,
  output logic [NSLOT-1:0]             f_filled,
  output logic [NSLOT*(KW/WW)-1:0]     f_seen
`endif
);
  localparam int unsigned NWORD = KW / WW;
  localparam int unsigned SB    = $clog2(NSLOT);
  localparam int unsigned WB    = $clog2(NWORD);

  logic [KW-1:0]     key    [NSLOT];
  logic [NSLOT-1:0]  locked;
  logic [NSLOT-1:0]  filled;                 // every word written at least once
  logic [NWORD-1:0]  seen   [NSLOT];         // which words have been written

  wire slot_locked = locked[host_slot];
  wire do_write    = host_we && !slot_locked && !host_wipe;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < NSLOT; s++) begin
        key[s]  <= '0;
        seen[s] <= '0;
      end
      locked     <= '0;
      filled     <= '0;
      err_locked <= 1'b0;
    end else begin
      err_locked <= host_we && slot_locked;

      if (host_wipe) begin
        // A wipe clears key material AND the seals: a sealed slot that could
        // not be cleared would be a slot the chip can never reuse, and the
        // usual reason to wipe is that something went wrong.
        for (int s = 0; s < NSLOT; s++) begin
          key[s]  <= '0;
          seen[s] <= '0;
        end
        locked <= '0;
        filled <= '0;
      end else begin
        if (do_write) begin
          key[host_slot][host_word*WW +: WW] <= host_wdata;
          seen[host_slot][host_word]         <= 1'b1;
          if (&(seen[host_slot] | (NWORD'(1) << host_word)))
            filled[host_slot] <= 1'b1;
        end
        // Sealing is one-way until a wipe. A slot can be sealed on the same
        // cycle as its last word is written.
        if (host_lock) locked[host_slot] <= 1'b1;
      end
    end
  end

  // ---- the host-visible word ----------------------------------------------
  // Metadata only, and deliberately written as a flat concatenation so that
  // anyone reading this can see at a glance that no array is indexed here.
  always_comb begin
    host_rdata = '0;
    host_rdata[0] = filled[host_rd_slot];
    host_rdata[1] = locked[host_rd_slot];
    host_rdata[15:8] = 8'(NSLOT);
    host_rdata[23:16] = 8'(NWORD);
  end

  // ---- the engine-visible key ---------------------------------------------
  assign eng_key   = eng_req ? key[eng_slot] : '0;
  assign eng_valid = eng_req && filled[eng_slot];

`ifdef FORMAL
  assign f_locked = locked;
  assign f_filled = filled;
  for (genvar g = 0; g < NSLOT; g++) begin : g_fseen
    assign f_seen[g*NWORD +: NWORD] = seen[g];
  end

  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;
  initial assume (!rst_n);

  always_ff @(posedge clk) if (past_valid && $past(rst_n) && rst_n) begin
    // A sealed slot keeps its contents until a wipe.
    for (int s = 0; s < NSLOT; s++)
      if ($past(locked[s]) && !$past(host_wipe))
        assert (key[s] == $past(key[s]));

    // Sealing is one-way until a wipe. Written over EVERY slot, not over
    // locked[host_slot]: $past(locked[host_slot]) samples the past value of
    // host_slot too, so that form compares one slot's history against a
    // different slot's present. The proof caught it, which is the argument
    // for proving rather than reasoning.
    for (int s = 0; s < NSLOT; s++)
      if ($past(locked[s]) && !$past(host_wipe)) assert (locked[s]);

    // A wipe leaves nothing behind.
    if ($past(host_wipe))
      for (int s = 0; s < NSLOT; s++)
        assert (key[s] == '0 && !locked[s] && !filled[s]);

    // An unfilled slot is never presented as usable.
    if (eng_req && !filled[eng_slot]) assert (!eng_valid);
  end
`endif
endmodule

`default_nettype wire
