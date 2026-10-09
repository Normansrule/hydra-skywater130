/*
 * hydra_tt_spi.sv
 *
 * HYDRA-130 - TT-A v2: oversampled SPI target (mode 0), byte stream interface
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY OVERSAMPLED, NOT CLOCKED BY SCK
 * ===========================================================================
 * The host is the TT demoboard's microcontroller toggling GPIO. Clocking a
 * register off SCK would add a second clock domain to a tile that has one,
 * with a CDC between SPI and the MOM. Sampling SCK in the 18 MHz domain keeps
 * a single clock. The cost is a speed limit: SCK must be below clk/8
 * (about 2 MHz), which is far above what GPIO bit-banging reaches.
 *
 * SCK, COPI and CSn all pass through the SAME two-flop synchroniser, so
 * their relative order is preserved: a COPI bit set up before an SCK edge on
 * the pins is still set up before it after synchronisation.
 *
 * ===========================================================================
 * PROTOCOL (mode 0: sample on rising SCK, change on falling SCK, MSB first)
 * ===========================================================================
 *   cs_start   CSn fell. tx_load pulses; the byte on tx_byte is loaded and
 *              its MSB is on CIPO before the first rising edge.
 *   rising     shift COPI in. After the 8th, rx_valid pulses with rx_byte;
 *              rx_index says which byte of the frame it was (saturates).
 *   falling    shift CIPO. At a byte boundary tx_load pulses instead and
 *              the next tx_byte is loaded.
 *   cs_end     CSn rose. The user commits (or discards) the frame here.
 *
 * tx_byte is sampled on the tx_load cycle. At a byte boundary that is at
 * least one clk after rx_valid (the falling edge follows the rising edge by
 * half an SCK period, >= 4 clk), so a register block can answer a command
 * byte with data from the very next byte.
 * ===========================================================================
 */
`default_nettype none

module hydra_tt_spi (
  input  wire        clk,
  input  wire        rst_n,

  input  wire        sck_i,
  input  wire        copi_i,
  input  wire        csn_i,
  output wire        cipo_o,

  output logic       cs_start,
  output logic       cs_end,
  output wire        cs_active,

  output logic       rx_valid,
  output logic [7:0] rx_byte,
  output logic [4:0] rx_index,     // 0 = command byte; saturates at 31

  output logic       tx_load,
  input  wire  [7:0] tx_byte
);

  // ---- synchroniser: identical depth for all three pins ---------------------
  logic [2:0] sck_s, csn_s;
  logic [1:0] copi_s;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sck_s  <= 3'b000;
      csn_s  <= 3'b111;          // idle high: no phantom frame out of reset
      copi_s <= 2'b00;
    end else begin
      sck_s  <= {sck_s[1:0], sck_i};
      csn_s  <= {csn_s[1:0], csn_i};
      copi_s <= {copi_s[0], copi_i};
    end
  end

  wire sck_rise = (sck_s[2:1] == 2'b01);
  wire sck_fall = (sck_s[2:1] == 2'b10);
  wire cs_fall  = (csn_s[2:1] == 2'b10);
  wire cs_rise  = (csn_s[2:1] == 2'b01);
  wire copi_b   = copi_s[1];
  assign cs_active = ~csn_s[1];

  // ---- receive -----------------------------------------------------------------
  logic [2:0] bitcnt;
  logic [6:0] rx_sr;
  logic       boundary;          // the last rising edge completed a byte
  logic [4:0] byte_cnt;

  // ---- transmit ----------------------------------------------------------------
  logic [7:0] tx_sr;
  assign cipo_o = tx_sr[7];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bitcnt   <= 3'd0;
      rx_sr    <= 7'd0;
      rx_byte  <= 8'd0;
      rx_valid <= 1'b0;
      rx_index <= 5'd0;
      byte_cnt <= 5'd0;
      boundary <= 1'b0;
      tx_sr    <= 8'd0;
      tx_load  <= 1'b0;
      cs_start <= 1'b0;
      cs_end   <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      tx_load  <= 1'b0;
      cs_start <= cs_fall;
      cs_end   <= cs_rise;

      if (cs_fall) begin
        bitcnt   <= 3'd0;
        byte_cnt <= 5'd0;
        boundary <= 1'b0;
        tx_load  <= 1'b1;
      end else if (cs_active) begin
        if (sck_rise) begin
          rx_sr  <= {rx_sr[5:0], copi_b};
          bitcnt <= bitcnt + 3'd1;
          if (bitcnt == 3'd7) begin
            rx_byte  <= {rx_sr, copi_b};
            rx_valid <= 1'b1;
            rx_index <= byte_cnt;
            if (byte_cnt != 5'd31) byte_cnt <= byte_cnt + 5'd1;
            boundary <= 1'b1;
          end
        end else if (sck_fall) begin
          if (boundary) begin
            boundary <= 1'b0;
            tx_load  <= 1'b1;
          end else begin
            tx_sr <= {tx_sr[6:0], 1'b0};
          end
        end
      end

      // tx_load was raised last cycle: take the byte the user presents now.
      if (tx_load) tx_sr <= tx_byte;
    end
  end

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Harness: a reference that records what the pins carried, bit by bit, and
  // checks the byte the block reports. It is written against pin semantics,
  // not against the shift register above.
  // ---------------------------------------------------------------------------
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;
  always_comb if (!past_valid) assume (!rst_n);

  // Reference sampling happens at the same synchronised instants.
  logic [7:0] ref_sr;
  logic [3:0] ref_n;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ref_sr <= 0; ref_n <= 0; end
    else if (cs_fall) begin ref_sr <= 0; ref_n <= 0; end
    else if (cs_active && sck_rise) begin
      ref_sr <= {ref_sr[6:0], copi_b};
      ref_n  <= (ref_n == 4'd8) ? 4'd1 : ref_n + 4'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (past_valid && rst_n) begin
      // R1: rx_valid only after exactly eight rising edges in this frame.
      if (rx_valid) assert (ref_n == 4'd8);
      // R2: the byte reported is the eight bits the pins carried.
      if (rx_valid) assert (rx_byte == ref_sr);
      // R3: rx_valid is a single-cycle pulse.
      if ($past(rx_valid)) assert (!rx_valid);
      // R4: a new frame always starts at bit 0 and byte 0.
      if ($past(cs_fall)) assert (bitcnt == 0 && byte_cnt == 0);
      // R5: the frame's first byte is reported as index 0.
      if (rx_valid && $past(byte_cnt) == 0) assert (rx_index == 0);
      // R6: whatever was presented on a load cycle is what goes out next.
      if ($past(tx_load)) assert (tx_sr == $past(tx_byte));
    end
  end

  // Bit-counter / reference agreement (inductive strengthening).
  always_comb if (rst_n) assert (ref_n == 0 ? bitcnt == 0 : bitcnt == ref_n[2:0]);
  always_comb if (rst_n) assert (ref_n <= 4'd8);
  // The bits received so far in this byte agree with the pins.
  always_comb if (rst_n)
    for (int i = 0; i < 7; i++)
      if (i < bitcnt) assert (rx_sr[i] == ref_sr[i]);
  // A pending rx_valid can only be the cycle right after a byte completed.
  always_comb if (rst_n && rx_valid) assert (bitcnt == 0 && boundary);

  always_ff @(posedge clk) if (past_valid) cover (rx_valid && rx_index == 1);
`endif

endmodule

`default_nettype wire
