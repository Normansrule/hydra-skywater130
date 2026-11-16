/*
 * hydra_secure_boot.sv -- the CPU runs only an image whose SHA-256 matches a
 *                         digest fixed in the mask
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT IT DOES
 * ===========================================================================
 * The host loads the CPU's program into its memory as before, writes the
 * image length and starts a boot. This block then reads the image back out
 * of the CPU memory itself, word by word, hashes it with hydra_measure (the
 * SHA-256 stream, checked against hashlib and formally proved in sec/), and
 * compares the digest with GOLDEN, a parameter fixed when the chip is made.
 *
 *   match     VERIFIED, sticky until reset. The CPU may now be launched. The
 *             host load port, the host read port into CPU memory and the
 *             CPU debug register port are closed for good (until reset), so
 *             the verified image cannot be changed or read out afterwards.
 *   mismatch  FAILED. The CPU stays refused. The host may load another image
 *             and boot again.
 *
 * While a boot runs, the host load port is closed too, so the image cannot
 * change between being read and being run. Every boot also extends the PCR
 * (measured boot), so the record of what was booted can be read back.
 *
 * ===========================================================================
 * WHAT THIS IS NOT
 * ===========================================================================
 * - Not a signature check. The root of trust is a hash pinned in the mask:
 *   one image (or one digest) per mask. Signed images (ECDSA or Ed25519)
 *   need a public-key engine this chip does not have; see
 *   docs/architecture/secure-boot.md.
 * - Not tamper resistant. Nothing here defends against probing, fault
 *   injection or side channels, and SkyWater 130 has no one-time-programmable
 *   memory, which is why GOLDEN is a mask parameter rather than a fuse.
 * - Nothing is formally proved about this block yet. tb_secure_boot checks it
 *   against hashlib and runs the negative cases; the SHA-256 and measurement
 *   blocks underneath carry their own proofs.
 *
 * The image is hashed in memory order: byte 0 of word 0 first (the CPU
 * memory stores little-endian words, so each word is byte-swapped into the
 * big-endian stream).
 * ===========================================================================
 */
`default_nettype none

module hydra_secure_boot #(
  parameter logic [255:0] GOLDEN = 256'd0,     // SHA-256 of the one image this mask runs
  parameter int           AW     = 14          // CPU memory word address bits
) (
  input  wire          clk,
  input  wire          rst_n,

  // host control
  input  wire          boot_start,              // pulse: measure and check the loaded image
  input  wire  [AW:0]  boot_len,                // image length in 32-bit words, 1 .. 2**AW

  // read port into the CPU memory (data one cycle after the address)
  output logic [AW-1:0] rd_addr,
  input  wire  [31:0]  rd_data,

  output wire          busy,
  output logic         verified,                // sticky until reset
  output logic         failed,                  // last boot did not match; cleared by a new boot
  output wire          lock_load,               // refuse host writes into CPU memory
  output wire          lock_debug,              // refuse host reads of CPU memory and registers
  output wire  [255:0] digest,                  // SHA-256 of the last image booted
  output wire  [255:0] pcr,                     // measured-boot record
  output logic [15:0]  boots                    // boots attempted since reset
);

  typedef enum logic [2:0] { B_IDLE, B_START, B_ADDR, B_FEED, B_HASH } st_e;
  st_e st;

  logic [AW:0]  len_q;
  logic [AW:0]  idx;                             // word being fed
  logic         m_start, m_valid, m_last;
  wire          m_start_ready, m_ready, m_busy, m_done, m_err;
  wire  [15:0]  m_ext;

  wire [31:0] be_word = {rd_data[7:0], rd_data[15:8], rd_data[23:16], rd_data[31:24]};

  hydra_measure u_meas (
    .clk(clk), .rst_n(rst_n),
    .start(m_start), .start_ready(m_start_ready),
    .in_valid(m_valid), .in_ready(m_ready), .in_data(be_word), .in_bytes(3'd4), .in_last(m_last),
    .busy(m_busy), .done(m_done), .err(m_err), .image_digest(digest), .pcr(pcr),
    .extend_count(m_ext));

  // A length of 0 or past the memory is refused before anything is read.
  wire len_ok = (boot_len != '0) && (boot_len <= (AW+1)'(1 << AW));

  always_comb begin
    m_start = (st == B_START) && m_start_ready;
    m_valid = (st == B_FEED);
    m_last  = (st == B_FEED) && (idx == len_q - 1'b1);
  end
  assign rd_addr = idx[AW-1:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= B_IDLE; len_q <= '0; idx <= '0;
      verified <= 1'b0; failed <= 1'b0; boots <= 16'd0;
    end else begin
      case (st)
        B_IDLE:
          if (boot_start && !verified) begin
            boots <= boots + 16'd1;
            if (len_ok) begin
              len_q <= boot_len; idx <= '0; failed <= 1'b0; st <= B_START;
            end else begin
              failed <= 1'b1;
            end
          end
        B_START:  if (m_start_ready) st <= B_ADDR;          // m_start fires this cycle
        B_ADDR:   st <= B_FEED;                             // rd_data valid next cycle
        B_FEED:
          if (m_ready) begin
            if (m_last) st <= B_HASH;
            else begin idx <= idx + 1'b1; st <= B_ADDR; end
          end
        B_HASH:
          if (m_done) begin
            if (digest == GOLDEN) verified <= 1'b1;
            else                  failed   <= 1'b1;
            st <= B_IDLE;
          end else if (m_err) begin
            failed <= 1'b1; st <= B_IDLE;
          end
        default: st <= B_IDLE;
      endcase
    end
  end

  assign busy       = (st != B_IDLE);
  assign lock_load  = verified || busy;
  assign lock_debug = verified;

  wire _unused = &{1'b0, m_busy, m_ext};

endmodule

`default_nettype wire
