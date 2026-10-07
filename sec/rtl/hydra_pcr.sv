/*
 * hydra_pcr.sv -- a measurement register that can only be extended
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * THE POINT
 * ===========================================================================
 * Measured boot works because the record of what ran cannot be rewritten by
 * what ran afterwards. A register software can set to any value proves
 * nothing at all: malicious code measures itself, does not like the answer,
 * and writes the value the verifier expected.
 *
 * So there is no write port. The only operation is EXTEND:
 *
 *     PCR  <-  SHA-256( PCR || measurement )
 *
 * Getting back to a chosen value would mean finding a preimage of SHA-256.
 * The register is cleared by reset and by nothing else -- and a reset is
 * visible, because everything measured before it is gone.
 *
 * ===========================================================================
 * THE PADDING IS FIXED, AND THAT IS WHY THIS IS SAFE
 * ===========================================================================
 * hydra_sha256 does not pad; software frames messages for it. That is
 * exactly the weakness that would sink a measurement register, because
 * software that chooses the framing chooses the answer.
 *
 * Here the message is ALWAYS the same shape: two 32-byte values, 64 bytes,
 * so the padding is a constant this module supplies itself --
 *
 *     block 0 : PCR (8 words) || measurement (8 words)
 *     block 1 : 0x80000000, thirteen zero words, then the length 512
 *
 * Software provides the measurement and nothing else. It cannot change the
 * length, cannot move the padding, and cannot make two different inputs
 * hash the same way by reframing them.
 */
`default_nettype none

module hydra_pcr (
  input  wire          clk,
  input  wire          rst_n,

  input  wire          extend,          // pulse: fold meas into the register
  input  wire [255:0]  meas,
  output logic         busy,
  output logic         done,

  output logic [255:0] pcr,
  output logic [15:0]  extend_count     // how many measurements are in there
);
  // ---- the hash engine -----------------------------------------------------
  logic         sha_init, sha_go, sha_w_we;
  logic [3:0]   sha_w_addr;
  logic [31:0]  sha_w_data;
  wire          sha_busy, sha_done;
  wire [255:0]  sha_digest;

  hydra_sha256 u_sha (
    .clk(clk), .rst_n(rst_n), .init(sha_init),
    .w_we(sha_w_we), .w_addr(sha_w_addr), .w_data(sha_w_data),
    .go(sha_go), .busy(sha_busy), .done(sha_done), .digest(sha_digest));

  typedef enum logic [2:0] {
    IDLE, INIT, LOAD0, RUN0, LOAD1, RUN1, FINISH
  } st_e;
  st_e st;

  logic [255:0] meas_q;
  logic [3:0]   widx;
  // Set when a block has been handed to the hash engine. Without it, the
  // "start" condition (!sha_busy && !sha_go) is TRUE AGAIN on the cycle the
  // engine finishes -- because busy clears and done pulses on the same edge
  // -- so the block is restarted forever and nothing ever completes.
  logic         issued;

  // Block 0 is the two values back to back; block 1 is the constant padding
  // for a 64-byte message. Both are selected by index rather than stored,
  // so there is no buffer for anything to be written into.
  wire [31:0] blk0_word = (widx < 4'd8)
                        ? pcr [(7 - widx) * 32 +: 32]
                        : meas_q[(15 - widx) * 32 +: 32];

  wire [31:0] blk1_word = (widx == 4'd0)  ? 32'h8000_0000
                        : (widx == 4'd15) ? 32'd512      // 64 bytes, in bits
                        :                   32'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; pcr <= '0; extend_count <= '0; meas_q <= '0; widx <= '0;
      sha_init <= 1'b0; sha_go <= 1'b0; sha_w_we <= 1'b0; issued <= 1'b0;
      sha_w_addr <= '0; sha_w_data <= '0;
      busy <= 1'b0; done <= 1'b0;
    end else begin
      sha_init <= 1'b0;
      sha_go   <= 1'b0;
      sha_w_we <= 1'b0;
      done     <= 1'b0;

      unique case (st)
        IDLE: if (extend) begin
          meas_q <= meas;
          busy   <= 1'b1;
          st     <= INIT;
        end

        INIT: begin
          sha_init <= 1'b1;        // every extend is a fresh hash
          widx     <= '0;
          st       <= LOAD0;
        end

        LOAD0: begin
          sha_w_we   <= 1'b1;
          sha_w_addr <= widx;
          sha_w_data <= blk0_word;
          if (widx == 4'd15) st <= RUN0;
          widx <= widx + 4'd1;
        end

        RUN0: begin
          if (!issued) begin sha_go <= 1'b1; issued <= 1'b1; end
          else if (sha_done) begin
            issued <= 1'b0; widx <= '0; st <= LOAD1;
          end
        end

        LOAD1: begin
          sha_w_we   <= 1'b1;
          sha_w_addr <= widx;
          sha_w_data <= blk1_word;
          if (widx == 4'd15) st <= RUN1;
          widx <= widx + 4'd1;
        end

        RUN1: begin
          if (!issued) begin sha_go <= 1'b1; issued <= 1'b1; end
          else if (sha_done) begin issued <= 1'b0; st <= FINISH; end
        end

        FINISH: begin
          pcr     <= sha_digest;
          extend_count <= extend_count + 16'd1;
          busy    <= 1'b0;
          done    <= 1'b1;
          st      <= IDLE;
        end

        default: st <= IDLE;
      endcase
    end
  end

`ifdef FORMAL
  logic started = 1'b0;
  always_ff @(posedge clk) started <= 1'b1;
  always_ff @(posedge clk) if (!started) assume (!rst_n);

  // Induction needs this: from an arbitrary state the solver may start with
  // busy set while the machine is IDLE, a state no real run reaches, and
  // then the "ignored while busy" property below has a counterexample that
  // cannot happen. The invariant is true by construction -- busy rises on
  // leaving IDLE and falls in FINISH -- and saying so is what lets the
  // proof close.
  always_ff @(posedge clk) if (started && rst_n) assert (busy == (st != IDLE));

  always_ff @(posedge clk) if (started && rst_n && $past(rst_n)) begin
    // THE property: the register changes only at the end of an extend.
    // There is no path by which software sets it, because there is no port
    // that writes it -- and this says so in a way a future edit cannot
    // quietly undo.
    if (pcr != $past(pcr)) assert ($past(st) == FINISH);

    // The counter moves with it, so a verifier can tell how many
    // measurements are folded in.
    if (extend_count != $past(extend_count)) assert ($past(st) == FINISH);

    // An extend request while busy is ignored rather than corrupting the
    // one in progress.
    if ($past(busy) && $past(extend)) assert (meas_q == $past(meas_q));
  end

  always_ff @(posedge clk) cover (started && done);
`endif
endmodule

`default_nettype wire
