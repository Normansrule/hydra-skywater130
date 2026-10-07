/*
 * hydra_basys3_selftest.sv -- first light on a Digilent Basys 3
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * EVERY USER-VISIBLE THING ON THE BOARD, ONE TEST EACH
 * ===========================================================================
 * The Basys 3 (Artix-7 XC7A35T-1CPG236C) has more to test than the ECP5
 * board: sixteen LEDs, sixteen switches, five buttons and a four-digit
 * seven-segment display. The lower eight LEDs and switches and the serial
 * port reuse hydra_fpga_selftest UNCHANGED -- it is already verified, and a
 * second copy of the same logic would be a second thing to get wrong.
 *
 *   power-on         LEDs 0-7 walk, twice (the shared core); the display
 *                    shows "HYdr" for two seconds -- every digit, distinct
 *   centre button    reset: replays both
 *   switches 0-7     the shared core: mirror mode or switch naming
 *   switches 8-15    LEDs 8-15 follow them directly
 *   up/down/left/right  each lights its own pattern on LEDs 8-15 while held
 *   the display      after the banner, the sixteen switches as four hex
 *                    digits -- switch 15 is the top bit of the left digit
 *   serial           banner, switch reports and echo (the shared core)
 *
 * Pins come from Digilent's own master constraints file, kept unmodified in
 * fpga/boards/basys3/Basys-3-Master.xdc.
 *
 * ===========================================================================
 * POLARITY, FROM THE BOARD'S REFERENCE MANUAL
 * ===========================================================================
 * LEDs, switches and buttons are active HIGH. The display is common-anode:
 * its anode enables and its segment lines are both active LOW. A display
 * driven with the wrong polarity shows the complement -- every unlit segment
 * lit -- which is exactly why the banner exists: "HYdr" inverted is
 * unmistakable.
 */
`default_nettype none

module hydra_basys3_selftest #(
  parameter int unsigned TICK         = 100_000,   // 100 MHz: cycles per millisecond
  parameter int unsigned CLKS_PER_BIT = 868,       // 100 MHz / 115200 (0.006% error)
  parameter int unsigned BANNER_MS    = 2000,
  parameter int unsigned DEBOUNCE_MS  = 10
) (
  input  wire        clk,
  input  wire        btnC, btnU, btnD, btnL, btnR,
  input  wire [15:0] sw,
  output logic [15:0] led,
  output logic [6:0] seg,          // active low: seg[0] = segment a
  output logic       dp,           // active low
  output logic [3:0] an,           // active low: an[0] = rightmost digit
  input  wire        RsRx,
  output wire        RsTx
);
  // ---- reset: power-on, plus the centre button -----------------------------
  // The FPGA's registers power up to their initial values, so a short counter
  // gives a clean reset at configuration. The button is synchronised before
  // it is used: it is an asynchronous input like any switch.
  logic [3:0] por = 4'd0;
  logic [1:0] btnc_s = 2'b00;
  always_ff @(posedge clk) begin
    btnc_s <= {btnc_s[0], btnC};
    if (btnc_s[1])            por <= 4'd0;
    else if (por != 4'hF)     por <= por + 4'd1;
  end
  wire rst_n = (por == 4'hF);

  // ---- the shared, already-verified core ------------------------------------
  wire [7:0] led_lo;
  hydra_fpga_selftest #(.TICK(TICK), .CLKS_PER_BIT(CLKS_PER_BIT),
                        .DEBOUNCE_MS(DEBOUNCE_MS)) u_core (
    .clk(clk), .rst_n(rst_n), .dip(sw[7:0]), .led(led_lo),
    .uart_rx_i(RsRx), .uart_tx_o(RsTx));

  // ---- millisecond tick ------------------------------------------------------
  logic [$clog2(TICK+1)-1:0] tick;
  wire ms = (tick == ($clog2(TICK+1))'(TICK - 1));
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) tick <= '0; else tick <= ms ? '0 : tick + 1'b1;

  // ---- upper switches and the four direction buttons -------------------------
  logic [15:0] sw_s1, sw_s2;
  logic [3:0]  b_s1, b_s2;                 // up, down, left, right
  always_ff @(posedge clk) begin
    sw_s1 <= sw;  sw_s2 <= sw_s1;
    b_s1  <= {btnU, btnD, btnL, btnR};  b_s2 <= b_s1;
  end

  // Each button has a pattern no other button and no single switch produces,
  // so the LEDs say WHICH button the FPGA saw.
  always_comb begin
    led[7:0] = led_lo;
    unique casez (b_s2)
      4'b1???: led[15:8] = 8'b1111_0000;   // up
      4'b01??: led[15:8] = 8'b0000_1111;   // down
      4'b001?: led[15:8] = 8'b1010_1010;   // left
      4'b0001: led[15:8] = 8'b0101_0101;   // right
      default: led[15:8] = sw_s2[15:8];
    endcase
  end

  // ---- the display -----------------------------------------------------------
  logic [11:0] since_reset_ms;
  logic [1:0]  digit;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      since_reset_ms <= '0; digit <= '0;
    end else if (ms) begin
      if (since_reset_ms != 12'(BANNER_MS)) since_reset_ms <= since_reset_ms + 12'd1;
      digit <= digit + 2'd1;               // one digit per millisecond: 250 Hz each
    end
  end
  wire banner = (since_reset_ms != 12'(BANNER_MS));

  // Segment patterns, bit 0 = segment a ... bit 6 = segment g, ACTIVE HIGH
  // here and inverted at the pin.
  function automatic logic [6:0] hex7(input logic [3:0] v);
    unique case (v)
      4'h0: return 7'h3F; 4'h1: return 7'h06; 4'h2: return 7'h5B; 4'h3: return 7'h4F;
      4'h4: return 7'h66; 4'h5: return 7'h6D; 4'h6: return 7'h7D; 4'h7: return 7'h07;
      4'h8: return 7'h7F; 4'h9: return 7'h6F; 4'hA: return 7'h77; 4'hB: return 7'h7C;
      4'hC: return 7'h39; 4'hD: return 7'h5E; 4'hE: return 7'h79; default: return 7'h71;
    endcase
  endfunction

  //                       digit 3   digit 2   digit 1   digit 0
  localparam logic [6:0] BAN [4] = '{7'h50,   7'h5E,    7'h6E,    7'h76};   // r d Y H
  // index 0 is digit 0 (rightmost): reading right to left gives r, d, Y, H

  logic [6:0] pattern;
  always_comb begin
    if (banner) pattern = BAN[digit];
    else        pattern = hex7(sw_s2[digit*4 +: 4]);
    seg = ~pattern;                       // active low
    dp  = 1'b1;                           // off
    an  = ~(4'b0001 << digit);            // one digit at a time, active low
  end
endmodule

`default_nettype wire
