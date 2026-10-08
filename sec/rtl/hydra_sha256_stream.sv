/*
 * hydra_sha256_stream.sv -- SHA-256 of a message, padded in HARDWARE
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY
 * ===========================================================================
 * hydra_sha256 compresses blocks; it does not frame messages. Software that
 * frames a message -- appends the 0x80 marker, the zeros and the 64-bit
 * length -- chooses what is hashed. That is harmless for a checksum and
 * fatal for measured boot: code that frames its own measurement can make
 * two different images produce the same "hash", or a hash of something
 * that is not the image at all.
 *
 * Here software supplies MESSAGE BYTES ONLY. This module counts every byte
 * it accepts and appends the padding itself, so the digest is SHA-256 of
 * exactly the bytes that went in -- the standard's function, not one with
 * a software-chosen length field.
 *
 * ===========================================================================
 * PROTOCOL
 * ===========================================================================
 *   start                     begin a new message (only while not hashing)
 *   in_valid / in_ready       one 32-bit word per handshake, big-endian:
 *                             the FIRST byte of the message is in [31:24]
 *   in_bytes                  4 on every word but the last; 0..4 on the last
 *   in_last                   this word ends the message
 *   done, digest              done pulses once; digest holds until start
 *   err                       a protocol error (fewer than 4 bytes without
 *                             in_last, or more than 4): the message is
 *                             abandoned and no digest is produced
 *
 * An empty message is a single handshake with in_last=1, in_bytes=0.
 * Nothing is accepted after in_last until the next start.
 *
 * One block of 16 words is written straight into the core as it arrives,
 * then compressed; input stalls (in_ready low) for the 65 cycles of each
 * compression. Throughput is not the point of this module.
 */
`default_nettype none

module hydra_sha256_stream #(
  // Proof only: also check the block count (needs a bounded run; see FORMAL).
  parameter bit F_BLOCKS = 1'b0
) (
  input  wire          clk,
  input  wire          rst_n,

  input  wire          start,
  input  wire          in_valid,
  output logic         in_ready,
  input  wire  [31:0]  in_data,
  input  wire  [2:0]   in_bytes,
  input  wire          in_last,

  output logic         busy,           // a message is being padded or hashed
  output logic         done,           // one cycle: digest is final
  output logic [255:0] digest,         // zero until a message completes
  output logic         err,            // sticky until start
  output logic [63:0]  msg_bits        // bits accepted so far: the length field
`ifdef FORMAL
  // The abstract core finishes a block whenever this is high -- any
  // latency at all, chosen by the solver. See the FORMAL section.
  , input wire         f_core_fin
`endif
);
  // ---- the core -------------------------------------------------------------
  logic         sha_init, sha_w_we, sha_go;
  logic [3:0]   sha_w_addr;
  logic [31:0]  sha_w_data;
  logic         sha_busy, sha_done;
  logic [255:0] sha_digest;

`ifndef FORMAL
  hydra_sha256 u_core (
    .clk(clk), .rst_n(rst_n), .init(sha_init),
    .w_we(sha_w_we), .w_addr(sha_w_addr), .w_data(sha_w_data),
    .go(sha_go), .busy(sha_busy), .done(sha_done), .digest(sha_digest));
`else
  // Abstract core for the proof: same handshake as hydra_sha256 -- busy
  // rises on the edge after go, and busy falls on the same edge done
  // pulses -- but the number of cycles in between is the solver's choice.
  // The controller is proved for every core latency; the arithmetic of the
  // real core is checked against hashlib in simulation.
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin sha_busy <= 1'b0; sha_done <= 1'b0; end
    else begin
      sha_done <= 1'b0;
      if (sha_go && !sha_busy) sha_busy <= 1'b1;
      else if (sha_busy && f_core_fin) begin sha_busy <= 1'b0; sha_done <= 1'b1; end
    end
  assign sha_digest = '0;
`endif

  // ---- the controller -------------------------------------------------------
  typedef enum logic [2:0] { S_IDLE, S_ACCEPT, S_GO, S_WAIT, S_PAD } st_e;
  st_e st;

  logic [4:0]  widx;        // next word slot in the block, 0..16
  logic [60:0] nbytes;      // message bytes accepted
  logic        pad80;       // the 0x80 marker has been written
  logic        len_hi;      // the high length word has been written
  logic        tail;        // in_last has been accepted
  logic        final_blk;   // the block in flight is the last one
  logic        have;        // digest is final

  assign msg_bits = {nbytes, 3'b000};

  wire hs   = in_valid && in_ready;
  wire bad  = (in_bytes > 3'd4) || (!in_last && in_bytes != 3'd4);

  // The last word, cut to its valid bytes, with the marker straight after.
  function automatic logic [31:0] tail_word(input logic [31:0] d, input logic [2:0] b);
    logic [31:0] keep;
    keep = (b == 3'd0) ? 32'h0 : (32'hFFFF_FFFF << (8 * (4 - b)));
    return (d & keep) | (32'h8000_0000 >> (8 * b));
  endfunction

  assign in_ready = (st == S_ACCEPT) && !sha_busy;
  assign busy     = (st == S_GO) || (st == S_WAIT) || (st == S_PAD);
  assign digest   = have ? sha_digest : '0;

  // What goes into the core this cycle.
  always_comb begin
    sha_init   = 1'b0;
    sha_go     = (st == S_GO);
    sha_w_we   = 1'b0;
    sha_w_addr = widx[3:0];
    sha_w_data = '0;

    if (start && (st == S_IDLE || st == S_ACCEPT)) sha_init = 1'b1;

    if (st == S_ACCEPT && hs && !bad && !start) begin
      if (!in_last || in_bytes == 3'd4) begin
        sha_w_we = 1'b1; sha_w_data = in_data;
      end else if (in_bytes != 3'd0) begin
        sha_w_we = 1'b1; sha_w_data = tail_word(in_data, in_bytes);
      end
    end

    if (st == S_PAD && widx != 5'd16) begin
      sha_w_we = 1'b1;
      if (!pad80)                 sha_w_data = 32'h8000_0000;
      else if (widx == 5'd14)     sha_w_data = msg_bits[63:32];
      else if (widx == 5'd15 && len_hi) sha_w_data = msg_bits[31:0];
      else                        sha_w_data = 32'h0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; widx <= '0; nbytes <= '0;
      pad80 <= 1'b0; len_hi <= 1'b0; tail <= 1'b0; final_blk <= 1'b0;
      have <= 1'b0; done <= 1'b0; err <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start && (st == S_IDLE || st == S_ACCEPT)) begin
        st <= S_ACCEPT; widx <= '0; nbytes <= '0;
        pad80 <= 1'b0; len_hi <= 1'b0; tail <= 1'b0; final_blk <= 1'b0;
        have <= 1'b0; err <= 1'b0;
      end else begin
        unique case (st)
          S_IDLE: ;

          S_ACCEPT: if (hs) begin
            if (bad) begin
              err <= 1'b1;               // abandon: no digest for this message
              st  <= S_IDLE;
            end else begin
              nbytes <= nbytes + 61'(in_bytes);
              if (!in_last) begin
                widx <= widx + 5'd1;
                if (widx == 5'd15) st <= S_GO;
              end else begin
                tail <= 1'b1;
                st   <= S_PAD;
                if (in_bytes != 3'd0) widx <= widx + 5'd1;
                // A partial word carries the marker; a full or empty one
                // leaves it for the padding loop.
                pad80 <= (in_bytes != 3'd0) && (in_bytes != 3'd4);
              end
            end
          end

          S_PAD: begin
            // One word per cycle: marker, zeros, length; compress whenever
            // a block fills. The length goes in words 14 and 15 of the
            // block the marker is in -- or of the next one, if the marker
            // landed in word 14 or 15.
            if (widx == 5'd16) begin
              st <= S_GO;
            end else begin
              widx <= widx + 5'd1;
              if (!pad80)                         pad80  <= 1'b1;
              else if (widx == 5'd14)             len_hi <= 1'b1;
              else if (widx == 5'd15 && len_hi) begin
                final_blk <= 1'b1;
                st        <= S_GO;
              end
            end
          end

          S_GO: st <= S_WAIT;

          S_WAIT: if (sha_done) begin
            widx <= '0;
            if (final_blk) begin
              st <= S_IDLE; have <= 1'b1; done <= 1'b1;
            end else
              st <= tail ? S_PAD : S_ACCEPT;
          end

          default: st <= S_IDLE;
        endcase
      end
    end
  end

`ifdef FORMAL
  // ===========================================================================
  // What is proved, for every input sequence and every core latency:
  //   1. every block handed to the core has all sixteen words written,
  //      each exactly once;
  //   2. a finished message used exactly the number of blocks the standard
  //      prescribes: floor((bytes + 8) / 64) + 1;
  //   3. the final block's words 14 and 15 hold the length in bits of
  //      exactly the bytes accepted -- counted here independently, from the
  //      handshakes, not from the design's own counter;
  //   4. the padding: if the marker fits in the final block it is the byte
  //      straight after the message, followed by zeros up to word 13; if
  //      not, words 0..13 of the final block are zero;
  //   5. nothing is accepted between in_last and the next start.
  // The digest arithmetic is the real core's, checked against hashlib.
  // ===========================================================================
  logic f_past = 1'b0;
  always_ff @(posedge clk) f_past <= 1'b1;
  always_ff @(posedge clk) if (!f_past) assume (!rst_n);

  logic [60:0] f_bytes;          // bytes accepted, counted from handshakes
  logic [5:0]  f_blocks;         // compressions since start (saturating)
  logic [15:0] f_mask;           // words written since the last go
  logic [4:0]  f_writes;         // how many writes since the last go
  logic [31:0] f_blk [0:15];     // the block as the core received it
  logic        f_twice;          // some word written twice in one block
  logic        f_ended;          // in_last accepted
  logic        f_xblk;           // a block was compressed after the marker

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_bytes <= '0; f_blocks <= '0; f_mask <= '0; f_writes <= '0;
      f_twice <= 1'b0; f_ended <= 1'b0; f_xblk <= 1'b0;
      for (int i = 0; i < 16; i++) f_blk[i] <= '0;
    end else begin
      if (sha_init) begin
        f_bytes <= '0; f_blocks <= '0; f_mask <= '0; f_writes <= '0;
        f_twice <= 1'b0; f_ended <= 1'b0; f_xblk <= 1'b0;
      end else begin
        if (hs && st == S_ACCEPT && !bad) begin
          f_bytes <= f_bytes + 61'(in_bytes);
          if (in_last) f_ended <= 1'b1;
        end
        if (sha_go && !sha_busy) begin
          f_mask <= '0; f_writes <= '0; f_twice <= 1'b0;
          if (f_blocks != 6'h3F) f_blocks <= f_blocks + 6'd1;
        end else if (sha_w_we) begin
          f_mask[sha_w_addr] <= 1'b1;
          if (f_mask[sha_w_addr]) f_twice <= 1'b1;
          if (f_writes != 5'd31) f_writes <= f_writes + 5'd1;
        end
      end
      if (sha_w_we) f_blk[sha_w_addr] <= sha_w_data;
      // The extra block begins when the marker block's compression ENDS:
      // until then f_blk still holds the marker block.
      if (!sha_init && sha_done && pad80 && !final_blk) f_xblk <= 1'b1;
    end
  end

  wire [63:0] f_len  = {f_bytes, 3'b000};
  wire [5:0]  f_pos  = f_bytes[5:0];               // byte offset in the last block
  wire [3:0]  f_mw   = f_pos[5:2];                 // word holding the marker
  wire [1:0]  f_mb   = f_pos[1:0];                 // its byte within the word
  wire [31:0] f_mword = f_blk[f_mw];
  wire [31:0] f_after = (f_mb == 2'd0) ? f_mword
                      : (f_mword << (8 * f_mb));  // marker byte and later ones

  // The padding and length checks hold from the moment the final block is
  // in flight until the next start -- not only on the done cycle. The core
  // may take any number of cycles, so a check made only at done could not
  // be carried by induction across an arbitrarily long wait.
  wire f_check = (st == S_WAIT && final_blk) || have;
  // Words written in the current block; once a message is finished the
  // design's index returns to 0 but the last block is complete.
  wire [4:0] f_w = (st == S_IDLE) ? 5'd16 : widx;

  always_ff @(posedge clk) if (f_past && rst_n) begin
    // 1. complete blocks
    if (sha_go && !sha_busy) assert (f_mask == 16'hFFFF && !f_twice && f_writes == 5'd16);

    if (f_check) begin
      // 3. the length field
      assert ({f_blk[14], f_blk[15]} == f_len);
      // 4. the padding
      if (f_pos < 6'd56) begin
        assert (f_after[31:24] == 8'h80);
        assert (f_after[23:0]  == 24'h0);
        for (int i = 0; i < 14; i++)
          if (i > f_mw) begin assert (f_blk[i] == 32'h0); end
      end else begin
        for (int i = 0; i < 14; i++) begin assert (f_blk[i] == 32'h0); end
      end
    end

    // 2. block count. It depends on the whole message's history, so it is
    //    checked by a BOUNDED run (task blocks, F_BLOCKS=1) and in
    //    simulation at every length to 1000 bytes, not by induction.
    if (F_BLOCKS && done && f_bytes < 61'd3900)
      assert (f_blocks == 6'((f_bytes + 61'd8) / 61'd64 + 61'd1));

    // Reachability: a message completes, and so does one that needs the
    // extra padding block -- so the properties above are not vacuous.
    cover (done);
    cover (done && f_pos >= 6'd56);

    // 5. nothing after in_last
    if (f_ended) assert (!in_ready);

    // ---- bookkeeping the induction needs (true, and proved like the rest) --
    assert (nbytes == f_bytes);
    assert (tail == f_ended);
    assert (!f_twice);
    assert (widx <= 5'd16);
    if (st == S_ACCEPT || st == S_PAD) assert (widx == f_writes);
    if (st == S_ACCEPT || st == S_PAD) assert (f_mask == 16'((17'd1 << widx) - 17'd1));
    if (st == S_ACCEPT) assert (widx <= 5'd15 && !tail && !pad80 && !len_hi && !final_blk && !have);
    if (st == S_PAD)    assert (tail && !final_blk && !have);
    if (st == S_GO)     assert (widx == 5'd16 && f_writes == 5'd16 && f_mask == 16'hFFFF && !have);
    if (st == S_WAIT)   assert (widx == 5'd16 && f_writes == 5'd0 && f_mask == 16'h0 && (sha_busy || sha_done) && !have);
    if (sha_busy || sha_done) assert (st == S_WAIT);
    if (st == S_ACCEPT || st == S_PAD || st == S_GO) assert (!sha_busy);
    if (len_hi && st != S_IDLE) assert (tail && pad80 && widx >= 5'd15);
    if (final_blk && st != S_IDLE) assert (len_hi);
    if (final_blk) assert (tail && len_hi && pad80);
    if (have) assert (st == S_IDLE && final_blk);
    if (done) assert (have);
    if (pad80 && st != S_IDLE) assert (tail);
    if (st == S_ACCEPT) assert (f_bytes[5:0] == {widx[3:0], 2'b00});
    if ((st == S_GO || st == S_WAIT) && !tail) assert (f_bytes[5:0] == 6'd0);
    if (f_xblk) assert (tail && pad80 && f_pos >= 6'd56);
    if (final_blk) assert (f_xblk == (f_pos >= 6'd56));
    if ((st == S_GO || st == S_WAIT) && !final_blk) assert (!len_hi);
    if ((st == S_GO || st == S_WAIT) && f_xblk)     assert (final_blk);
    if (len_hi && st != S_IDLE) assert (final_blk || (st == S_PAD && widx == 5'd15));

    // The padding as it is being written. T: from in_last until start.
    if ((tail && st != S_IDLE) || have) begin
      if (!pad80)
        // marker not yet written: it goes in the next slot, which is where
        // the message ended (a full or empty last word)
      begin
        assert (f_mb == 2'd0 && !f_xblk &&
                (f_w == {1'b0, f_mw} || (f_w == 5'd16 && f_pos == 6'd0)));
      end else if (!f_xblk) begin
        // marker written in this block, right after the message
        assert (f_w > {1'b0, f_mw});
        assert (f_after[31:24] == 8'h80 && f_after[23:0] == 24'h0);
        if (f_pos < 6'd56) begin assert (f_w <= 5'd14 || len_hi); end
        else               begin assert (!len_hi); end
      end
      for (int i = 0; i < 14; i++)
        if (i < f_w)
          if (f_xblk || (pad80 && i > f_mw)) assert (f_blk[i] == 32'h0);
      if (f_w > 5'd14) begin
        if (len_hi) begin assert (f_blk[14] == f_len[63:32]); end
        else if (f_xblk || (pad80 && f_mw < 4'd14)) begin assert (f_blk[14] == 32'h0); end
      end
      if (f_w > 5'd15) begin
        if (final_blk) begin assert (f_blk[15] == f_len[31:0]); end
        else if (f_xblk || (pad80 && f_mw < 4'd15)) begin assert (f_blk[15] == 32'h0); end
      end
    end
  end
`endif
endmodule

`default_nettype wire
