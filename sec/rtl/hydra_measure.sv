/*
 * hydra_measure.sv -- measure an image into a PCR, with no software between
 *                     the bytes and the record, on ONE SHA-256 core
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Measured boot, the hardware half:
 *
 *     digest  =  SHA-256( image )
 *     PCR    <-  SHA-256( PCR || digest )
 *
 * Software streams the next stage's BYTES in. It never sees or supplies the
 * digest: hydra_sha256_stream pads and hashes the bytes in hardware. Then
 * this module feeds the extend message -- the old PCR and the digest, 64
 * bytes, from its own registers -- through the SAME stream, and writes the
 * result into the PCR. While it does, the input port is closed.
 *
 * Until 2026-10-08 this held two SHA-256 cores: one for the image and one
 * inside hydra_pcr. An extend is just another padded 64-byte message, so one
 * core serves both, which saves a whole compression engine (7,419 cells).
 * hydra_pcr stays in the repository as the standalone register.
 *
 * WHAT IS PROVED (FORMAL section, every input sequence, any core latency):
 *   1. the PCR changes only on the cycle an extend finishes, and the extend
 *      counter moves with it, by exactly one;
 *   2. software cannot hand the stream a word outside the image phase --
 *      the extend message comes only from this module's registers;
 *   3. an abandoned image (protocol error) never reaches the PCR.
 * The values -- digest and chain -- are checked against hashlib in
 * tb_measure.
 */
`default_nettype none

module hydra_measure (
  input  wire          clk,
  input  wire          rst_n,

  input  wire          start,          // begin measuring an image
  output logic         start_ready,    // start will be accepted this cycle
  input  wire          in_valid,
  output logic         in_ready,
  input  wire  [31:0]  in_data,        // image bytes, big-endian words
  input  wire  [2:0]   in_bytes,       // 4, or 0..4 on the last word
  input  wire          in_last,

  output logic         busy,
  output logic         done,           // the measurement is in the PCR
  output logic         err,            // protocol error: image abandoned, PCR untouched
  output logic [255:0] image_digest,   // SHA-256 of the last image, for the event log
  output logic [255:0] pcr,
  output logic [15:0]  extend_count
`ifdef FORMAL
  , input wire         f_core_fin      // the abstract core's latency, solver's choice
`endif
);
  typedef enum logic [2:0] { P_IDLE, P_IMAGE, P_EXT_START, P_EXT_FEED, P_EXT_WAIT } ph_e;
  ph_e ph;

  // ---- the one stream, and who drives it ------------------------------------
  logic         s_start, s_valid, s_ready, s_last, s_busy, s_done, s_err;
  logic [31:0]  s_data;
  logic [2:0]   s_bytes;
  logic [255:0] s_digest;
  logic [63:0]  s_bits;

  hydra_sha256_stream u_sha (
    .clk(clk), .rst_n(rst_n), .start(s_start),
    .in_valid(s_valid), .in_ready(s_ready), .in_data(s_data),
    .in_bytes(s_bytes), .in_last(s_last),
    .busy(s_busy), .done(s_done), .digest(s_digest), .err(s_err), .msg_bits(s_bits)
`ifdef FORMAL
    , .f_core_fin(f_core_fin)
`endif
  );

  logic [3:0]   widx;                  // extend message word, 0..15
  logic [255:0] img_q;                 // the image digest, held for the extend
  wire  [511:0] ext_msg = {pcr, img_q};
  wire  [31:0]  ext_word = ext_msg[511 - 32*widx -: 32];

  // Software reaches the stream ONLY in the image phase.
  assign start_ready = (ph == P_IDLE) && !s_busy;
  assign in_ready    = (ph == P_IMAGE) && s_ready;

  always_comb begin
    s_start = 1'b0; s_valid = 1'b0; s_data = '0; s_bytes = 3'd4; s_last = 1'b0;
    unique case (ph)
      P_IDLE:      s_start = start;
      P_IMAGE:     begin s_valid = in_valid; s_data = in_data; s_bytes = in_bytes; s_last = in_last; end
      P_EXT_START: s_start = 1'b1;
      P_EXT_FEED:  begin s_valid = 1'b1; s_data = ext_word; s_bytes = 3'd4; s_last = (widx == 4'd15); end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= P_IDLE; widx <= '0; img_q <= '0; pcr <= '0; extend_count <= '0;
      done <= 1'b0; err <= 1'b0;
    end else begin
      done <= 1'b0;
      unique case (ph)
        P_IDLE: if (start && start_ready) begin
          ph <= P_IMAGE; err <= 1'b0;
        end
        P_IMAGE: begin
          if (s_err) begin
            ph <= P_IDLE; err <= 1'b1;         // abandoned: the PCR is not touched
          end else if (s_done) begin
            img_q <= s_digest;
            ph    <= P_EXT_START;
          end
        end
        P_EXT_START: begin widx <= '0; ph <= P_EXT_FEED; end
        P_EXT_FEED: if (s_ready) begin
          widx <= widx + 4'd1;
          if (widx == 4'd15) ph <= P_EXT_WAIT;
        end
        P_EXT_WAIT: if (s_done) begin
          pcr          <= s_digest;
          extend_count <= extend_count + 16'd1;
          done         <= 1'b1;
          ph           <= P_IDLE;
        end
        default: ph <= P_IDLE;
      endcase
    end
  end

  assign busy         = (ph != P_IDLE);
  assign image_digest = img_q;

`ifdef FORMAL
  logic f_past = 1'b0;
  always_ff @(posedge clk) f_past <= 1'b1;
  always_ff @(posedge clk) if (!f_past) assume (!rst_n);

  always_ff @(posedge clk) if (f_past && rst_n && $past(rst_n)) begin
    // 1. the PCR moves only as an extend finishes, with the counter
    if (pcr != $past(pcr) || extend_count != $past(extend_count)) begin
      assert ($past(ph) == P_EXT_WAIT && $past(s_done));
      assert (extend_count == $past(extend_count) + 16'd1);
    end
    // 3. an abandoned image never reaches the PCR
    if ($past(ph) == P_IMAGE && $past(s_err)) assert (pcr == $past(pcr) && ph == P_IDLE);
  end

  always_ff @(posedge clk) if (f_past && rst_n) begin
    // 2. software reaches the stream only while an image is being measured
    if (ph != P_IMAGE) assert (!in_ready);
    if (ph == P_EXT_FEED || ph == P_EXT_START) assert (s_data == ext_word || ph == P_EXT_START);

    // bookkeeping for the induction
    if (ph == P_EXT_WAIT || ph == P_EXT_FEED || ph == P_EXT_START) assert (!s_err);
    cover (done);
  end
`endif
endmodule

`default_nettype wire
