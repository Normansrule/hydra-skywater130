/*
 * hydra_dma_gemm.sv -- operand streamer between the scratchpad and an engine
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT IT REPLACES
 * ===========================================================================
 * Every engine adapter so far fed its engine from a pattern generator, with
 * a comment admitting the operands were synthetic. This reads REAL operands
 * out of a scratchpad, hands them to the engine one slice per cycle, and
 * writes the results back. That is the last piece between "the arithmetic is
 * real" and "the whole path is real".
 *
 * ===========================================================================
 * WHERE THE ADDRESSES COME FROM
 * ===========================================================================
 * The work descriptor has no address field. It has 35 reserved bits, and the
 * vector unit already took [2:0] for its lane opcode, so this allocates:
 *
 *      wd[12:3]    base_a      word address in the A bank
 *      wd[22:13]   base_b      word address in the B bank
 *      wd[32:23]   base_c      word address in the C bank
 *
 * Written here and in docs/ISA.md rather than only in a decoder, because a
 * later use of those bits for something else collides silently -- a matrix
 * multiply quietly reading the wrong region. Ten bits each caps a bank at
 * 1024 words, which is the size instantiated below; widening the bank means
 * widening the field, and the two are checked against each other by an
 * elaboration assertion rather than by memory.
 *
 * ===========================================================================
 * THE ONE-CYCLE MEMORY LATENCY
 * ===========================================================================
 * The scratchpad registers its read, so the word for address issued at cycle
 * t arrives at t+1. The streamer therefore runs one address ahead of the
 * engine and holds `op_valid` on the data that has landed, not the address
 * it just issued. Getting that wrong feeds the engine the previous slice --
 * every result wrong by one position, which is exactly the kind of fault
 * that survives a smoke test.
 */
`default_nettype none

module hydra_dma_gemm #(
  parameter int unsigned AW    = 10,     // bank address width
  parameter int unsigned DW    = 32,     // one operand slice per bank word
  parameter int unsigned CNTW  = 16
) (
  input  wire              clk,
  input  wire              rst_n,

  // ---- job, from the engine adapter --------------------------------------
  input  wire              start,
  input  wire [AW-1:0]     base_a,
  input  wire [AW-1:0]     base_b,
  input  wire [AW-1:0]     base_c,
  input  wire [CNTW-1:0]   k_slices,
  // How many results this job produces. An input rather than a parameter:
  // the array always writes N*N, but the vector unit writes one per lane
  // per group for an elementwise operation and exactly one for a
  // reduction. A parameter would have forced a second copy of this module.
  input  wire [CNTW-1:0]   n_results,
  output logic             busy,

  // ---- scratchpad ---------------------------------------------------------
  output logic [AW-1:0]    a_addr,
  input  wire [DW-1:0]     a_rdata,
  output logic [AW-1:0]    b_addr,
  input  wire [DW-1:0]     b_rdata,
  // A third operand stream, for engines that need one (the butterfly
  // engine's twiddle factors). It shares the read pointer, because every
  // stream advances together by construction; engines with two operands
  // leave it unconnected.
  output logic [AW-1:0]    w_addr,
  input  wire [DW-1:0]     w_rdata,
  output logic [AW-1:0]    c_addr,
  output logic             c_we,
  output logic [31:0]      c_wdata,

  // ---- engine operand port ------------------------------------------------
  output logic             op_valid,
  input  wire              op_ready,
  output logic [DW-1:0]    op_a,
  output logic [DW-1:0]    op_b,
  output logic [DW-1:0]    op_w,

  // ---- engine result port -------------------------------------------------
  input  wire              res_valid,
  input  wire [31:0]       res_data
);
  typedef enum logic [1:0] {S_IDLE, S_PRIME, S_STREAM, S_DRAIN} state_e;

  // ===========================================================================
  // THE PIPELINE, CYCLE BY CYCLE
  // ===========================================================================
  // The bank reads EVERY cycle: its output register holds the word for the
  // address presented in the previous cycle. So there are two stages -- the
  // bank's output register and the holding register below -- and the only
  // way to keep a fetched word alive through a stall is to present the SAME
  // address again. That is the whole mechanism:
  //
  //   capture this cycle  ->  present address cur+1 (fetch ahead)
  //   no capture          ->  present address cur   (the bank re-reads the
  //                                                   word it already holds)
  //
  // Two earlier versions got this wrong, both caught by the vector unit,
  // which stalls four cycles per group while its results serialise:
  //
  //   1. no holding register: the prefetched word was overwritten during the
  //      stall and the second group arrived undefined;
  //   2. a holding register that captured in PRIME: the bank had not yet
  //      answered, and counting that phantom capture meant the last group
  //      was never fetched -- the job never completed.
  //
  // The array never stalls, which is why it passed with both.
  //
  //   cycle   state   address   bank output      hold
  //   C1      PRIME   b+0       (stale)          --
  //   C2      STREAM  b+1 (cap) mem[b+0]         --      capture g0
  //   C3      STREAM  b+2 (cap) mem[b+1]         g0      xfer g0, capture g1
  //   C3'     STREAM  b+1       mem[b+1]         g0      stall: re-present b+1
  // ===========================================================================
  state_e          st_q;
  logic [CNTW-1:0] k_q;             // groups in this job
  // Latched at the start of the job, like everything else the job depends
  // on. It used to be read straight from the input for the whole job -- and
  // the adapters derive it from the descriptor, which arrives on the
  // crossbar's SHARED bus. A dispatch to another engine while this one was
  // still draining would have changed the count mid-job. Mutation testing
  // found it: ignoring the count entirely went unnoticed.
  logic [CNTW-1:0] n_q;
  logic [CNTW-1:0] k_left_q;        // groups still to hand to the engine
  logic [DW-1:0]   hold_a_q, hold_b_q, hold_w_q;
  logic            hold_valid_q;
  wire  [CNTW-1:0] cur;             // index of the word in the bank output

  // A job is only taken when the streamer is idle. Before this, a start
  // arriving during DRAIN reloaded the address generator while the state
  // machine ignored it: the job was silently dropped and the engine would
  // have waited for operands forever. The engines' own timing happens to
  // keep that from occurring today -- the proof showed nothing guarantees
  // it. `busy` is the other half: adapters must not accept work while it
  // is high, and both do.
  wire go      = start && (st_q == S_IDLE);
  wire xfer    = op_valid && op_ready;
  wire bank_ok = (st_q == S_STREAM) && (cur < k_q);
  wire capture = bank_ok && (!hold_valid_q || xfer);

  hydra_dma_agen #(.AW(AW), .CNTW(CNTW)) u_agen (
    .clk(clk), .rst_n(rst_n), .load(go),
    .base_a(base_a), .base_b(base_b), .base_c(base_c),
    .step_rd(capture), .peek(capture), .step_wr(res_valid),
    .addr_a(a_addr), .addr_b(b_addr), .addr_c(c_addr),
    .rd_count(cur), .wr_count());

  assign w_addr = a_addr;          // one pointer, all operand banks

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= S_IDLE; k_q <= '0; k_left_q <= '0; n_q <= '0;
      hold_valid_q <= 1'b0; hold_a_q <= '0; hold_b_q <= '0; hold_w_q <= '0;
    end else begin
      if (capture) begin
        hold_a_q     <= a_rdata;
        hold_b_q     <= b_rdata;
        hold_w_q     <= w_rdata;
        hold_valid_q <= 1'b1;
      end else if (xfer) begin
        hold_valid_q <= 1'b0;
      end

      unique case (st_q)
        S_IDLE: if (go) begin
          k_q          <= k_slices;
          n_q          <= n_results;
          k_left_q     <= k_slices;
          hold_valid_q <= 1'b0;
          // A zero-length job streams nothing. Without this guard the
          // consumption counter decrements from zero and wraps.
          st_q         <= (k_slices == '0) ? S_IDLE : S_PRIME;
        end

        // Exactly one cycle: the bank answering the first address.
        S_PRIME: st_q <= S_STREAM;

        S_STREAM: if (xfer) begin
          if (k_left_q == CNTW'(1)) st_q <= S_DRAIN;
          k_left_q <= k_left_q - CNTW'(1);
        end

        S_DRAIN: if (!res_valid && !busy_hold) st_q <= S_IDLE;

        default: st_q <= S_IDLE;
      endcase
    end
  end

  // Held until the expected number of results has been written, so a job is
  // not declared finished with its last result still in flight.
  logic [CNTW-1:0] res_seen_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          res_seen_q <= '0;
    else if (go)         res_seen_q <= '0;
    else if (res_valid)  res_seen_q <= res_seen_q + CNTW'(1);
  end
  wire busy_hold = (res_seen_q < n_q);

  assign op_valid = (st_q == S_STREAM) && hold_valid_q;
  assign op_a     = hold_a_q;
  assign op_b     = hold_b_q;
  assign op_w     = hold_w_q;
  assign c_we     = res_valid;
  assign c_wdata  = res_data;
  assign busy     = (st_q != S_IDLE);

`ifdef FORMAL
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;

  // The solver starts from an arbitrary register state unless told
  // otherwise, and it found one: the counterexample had the streamer
  // already mid-job at time zero, having never been reset. Real hardware
  // powers up in reset, so say so -- rather than weakening the property
  // to accommodate a state the chip cannot be in.
  initial assume (!rst_n);
  always_ff @(posedge clk) assume (st_q <= S_DRAIN);

  always_ff @(posedge clk) if (past_valid && $past(rst_n) && rst_n) begin
    // An operand is only ever presented from the holding register, never
    // straight off the bank output.
    if (op_valid) assert (hold_valid_q);
    // THE property the two broken versions violated: while a held word is
    // waiting and not being taken, nothing is captured over it, so it
    // cannot be lost. A stalling engine gets exactly the word it was
    // offered, however long it stalls.
    if (hold_valid_q && !xfer) assert (!capture);
    // Every group handed over was fetched first: consumption never runs
    // ahead of the bank.
    if (st_q == S_STREAM) assert ((k_q - k_left_q) <= cur);
    // The fetch pointer never runs past the job.
    assert (cur <= k_q || st_q == S_IDLE);
    // The holding register is empty in the wait state, by construction:
    // it is cleared when the job starts and nothing can capture before the
    // bank has answered. This is why "offer an operand during the wait"
    // is no longer a hazard -- there is never one to offer.
    if (st_q == S_PRIME) assert (!hold_valid_q);
    // The count it waits for is the count the job ASKED for, captured at
    // the start. Without this link the property below is relative to n_q
    // itself and holds trivially if n_q is wrong -- which is exactly how
    // the "not latched" mutation survived the first version of this proof.
    if ($past(go)) assert (n_q == $past(n_results));
    // The streamer does not declare itself free until every result of the
    // job has been written.
    if ($past(st_q) == S_DRAIN && st_q == S_IDLE) assert ($past(res_seen_q) >= $past(n_q));
    // Never present an operand during the wait state. Simulation alone
    // cannot see this one: the array happens to be clearing its
    // accumulators for exactly that cycle, so it never takes the early
    // word and the fault is invisible. That is a coupling between two
    // modules' timing, not a guarantee -- an engine that asserted ready
    // immediately would receive whatever the bank held before the job.
    // Proving it here makes the streamer correct on its own terms.
    assert (!(op_valid && (st_q == S_PRIME)));
    // Never write a result the engine did not produce.
    if (c_we) assert (res_valid);
    // A job in progress stays busy.
    if ($past(busy) && $past(st_q) != S_DRAIN) assert (busy);
    // The read address never runs past the job: k_left only decreases.
    if ($past(st_q) == S_STREAM && st_q == S_STREAM)
      assert (k_left_q <= $past(k_left_q));
    // The counter is non-zero from the moment a job starts until it ends,
    // which is what makes the decrement safe. Asserted across BOTH active
    // states, not assumed: an assumption here would have hidden the
    // zero-length wrap instead of exposing it -- which is exactly what the
    // first version of this proof did, until the mutation for that bug
    // survived and gave it away.
    if (st_q == S_PRIME || st_q == S_STREAM) assert (k_left_q != '0);
  end
`endif
endmodule

`default_nettype wire
