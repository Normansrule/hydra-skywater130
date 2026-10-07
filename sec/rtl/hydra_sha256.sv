/*
 * hydra_sha256.sv -- SHA-256 block compression
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY THIS ONE FIRST
 * ===========================================================================
 * Measured boot needs a hash before it needs anything else: the immutable
 * first stage measures the next stage and records what it found. Without
 * that, a key vault and a mailbox protect a boot process nobody can
 * describe.
 *
 * SHA-256 is also the easiest engine in this project to be honest about,
 * because the answer is not a matter of opinion. Test vectors are published,
 * and an independent model is one line of Python calling a library that was
 * not written by anyone involved here. A disagreement means this file is
 * wrong; there is no room to argue the model misread the specification.
 *
 * ===========================================================================
 * WHAT IT DOES
 * ===========================================================================
 * It compresses ONE 512-bit block into the running state, 64 rounds at one
 * round per cycle. Sixteen message words are loaded, `go` runs the block,
 * `done` says the state has been updated.
 *
 * PADDING IS NOT DONE HERE and that is a real limitation, not an oversight
 * deferred quietly. A message must be padded -- the 1 bit, the zeros, the
 * 64-bit length -- before its blocks arrive. Software does it today
 * (sha256_model.py shows exactly how). Hardware padding matters when the
 * hash is over something software must not be trusted to frame correctly,
 * which is precisely the measured-boot case, so this will need revisiting
 * before it guards a boot chain.
 *
 * The message schedule keeps sixteen words and rotates, rather than
 * expanding all 64 up front: 64 words of storage would be four times the
 * registers for no gain at one round per cycle.
 */
`default_nettype none

module hydra_sha256 (
  input  wire          clk,
  input  wire          rst_n,

  input  wire          init,          // load the standard initial state
  input  wire          w_we,          // load one message word
  input  wire [3:0]    w_addr,
  input  wire [31:0]   w_data,

  input  wire          go,            // compress the loaded block
  output logic         busy,
  output logic         done,          // one cycle, when the state is updated

  output logic [255:0] digest         // H0..H7, H0 in the high bits
);
  // First 32 bits of the fractional parts of the cube roots of the first
  // 64 primes, as the standard specifies.
  localparam logic [31:0] K [0:63] = '{
    32'h428a2f98, 32'h71374491, 32'hb5c0fbcf, 32'he9b5dba5,
    32'h3956c25b, 32'h59f111f1, 32'h923f82a4, 32'hab1c5ed5,
    32'hd807aa98, 32'h12835b01, 32'h243185be, 32'h550c7dc3,
    32'h72be5d74, 32'h80deb1fe, 32'h9bdc06a7, 32'hc19bf174,
    32'he49b69c1, 32'hefbe4786, 32'h0fc19dc6, 32'h240ca1cc,
    32'h2de92c6f, 32'h4a7484aa, 32'h5cb0a9dc, 32'h76f988da,
    32'h983e5152, 32'ha831c66d, 32'hb00327c8, 32'hbf597fc7,
    32'hc6e00bf3, 32'hd5a79147, 32'h06ca6351, 32'h14292967,
    32'h27b70a85, 32'h2e1b2138, 32'h4d2c6dfc, 32'h53380d13,
    32'h650a7354, 32'h766a0abb, 32'h81c2c92e, 32'h92722c85,
    32'ha2bfe8a1, 32'ha81a664b, 32'hc24b8b70, 32'hc76c51a3,
    32'hd192e819, 32'hd6990624, 32'hf40e3585, 32'h106aa070,
    32'h19a4c116, 32'h1e376c08, 32'h2748774c, 32'h34b0bcb5,
    32'h391c0cb3, 32'h4ed8aa4a, 32'h5b9cca4f, 32'h682e6ff3,
    32'h748f82ee, 32'h78a5636f, 32'h84c87814, 32'h8cc70208,
    32'h90befffa, 32'ha4506ceb, 32'hbef9a3f7, 32'hc67178f2};

  localparam logic [31:0] IV [0:7] = '{
    32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
    32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};

  function automatic logic [31:0] rotr(input logic [31:0] x, input int n);
    return (x >> n) | (x << (32 - n));
  endfunction

  wire [31:0] w_cur = w[0];

  logic [31:0] h [0:7];
  logic [31:0] a, b, c, d, e, f, g, hh;
  logic [31:0] w [0:15];
  logic [6:0]  round;

  // Schedule: the next word from the four the standard names.
  wire [31:0] s0   = rotr(w[1], 7)  ^ rotr(w[1], 18) ^ (w[1] >> 3);
  wire [31:0] s1   = rotr(w[14], 17) ^ rotr(w[14], 19) ^ (w[14] >> 10);
  wire [31:0] w_nx = w[0] + s0 + w[9] + s1;

  wire [31:0] S1   = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
  wire [31:0] ch   = (e & f) ^ (~e & g);
  wire [31:0] t1   = hh + S1 + ch + K[round[5:0]] + w_cur;
  wire [31:0] S0   = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
  wire [31:0] maj  = (a & b) ^ (a & c) ^ (b & c);
  wire [31:0] t2   = S0 + maj;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 8; i++) h[i] <= IV[i];
      for (int i = 0; i < 16; i++) w[i] <= '0;
      busy <= 1'b0; done <= 1'b0; round <= '0;
      a <= '0; b <= '0; c <= '0; d <= '0;
      e <= '0; f <= '0; g <= '0; hh <= '0;
    end else begin
      done <= 1'b0;

      if (init && !busy) begin
        for (int i = 0; i < 8; i++) h[i] <= IV[i];
      end

      if (w_we && !busy) w[w_addr] <= w_data;

      if (go && !busy) begin
        busy  <= 1'b1;
        round <= '0;
        a <= h[0]; b <= h[1]; c <= h[2]; d <= h[3];
        e <= h[4]; f <= h[5]; g <= h[6]; hh <= h[7];
      end else if (busy) begin
        if (round == 7'd64) begin
          // Feed-forward: the compressed block is ADDED to the previous
          // state. Leaving this out yields a function that looks like a
          // hash and is trivially invertible per block.
          h[0] <= h[0] + a; h[1] <= h[1] + b;
          h[2] <= h[2] + c; h[3] <= h[3] + d;
          h[4] <= h[4] + e; h[5] <= h[5] + f;
          h[6] <= h[6] + g; h[7] <= h[7] + hh;
          busy <= 1'b0;
          done <= 1'b1;
        end else begin
          hh <= g; g <= f; f <= e;
          e  <= d + t1;
          d  <= c; c <= b; b <= a;
          a  <= t1 + t2;

          // Rotate the window and feed in the NEXT expanded word, from
          // round 0 onward. At round t the window holds W[t..t+15] and the
          // schedule formula produces W[t+16] from exactly those, so the
          // expansion is never "not started yet": holding w[15] for the
          // first fifteen rounds duplicates W15 and corrupts every digest,
          // including the published "abc" vector.
          for (int i = 0; i < 15; i++) w[i] <= w[i+1];
          w[15] <= w_nx;

          round <= round + 7'd1;
        end
      end
    end
  end

  assign digest = {h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]};
endmodule

`default_nettype wire
