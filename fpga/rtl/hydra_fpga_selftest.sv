/*
 * hydra_fpga_selftest.sv -- first light on a new board
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY THIS COMES BEFORE ANYTHING ELSE
 * ===========================================================================
 * When the dispatcher image does nothing on a real board, the list of
 * suspects is enormous: the design, the pin map, the clock, a jumper, the
 * cable, the driver, LED polarity, the flashing step. This image has almost
 * no design in it, so if IT fails, the fault is in the setup -- and each
 * behaviour below tests exactly one link in that chain:
 *
 *   power-on sweep   the clock runs, the bitstream loaded, every LED works,
 *                    and LED POLARITY is visible at a glance
 *   the button       it is the reset: pressing it replays the sweep
 *   the switches     each one drives its own LED, live
 *   pattern mode     the FPGA names which switch it saw change
 *   heartbeat        the clock is still running, one blink a second
 *   serial port      a banner at power-on, a line per switch change, and
 *                    every byte received is echoed back
 *
 * ===========================================================================
 * READING THE LEDS
 * ===========================================================================
 * After power-on or a button press, ONE LED walks from 0 to 7, twice.
 *
 *   One LIT LED walking      -- polarity correct, carry on.
 *   One DARK LED walking     -- polarity is inverted. The pin map is right
 *                               and the logic is right; change led_active in
 *                               fpga/boards/ecp5-evn.yaml and rebuild.
 *   Nothing at all           -- the bitstream did not load, or the clock is
 *                               not running. See FPGA_BRINGUP.md.
 *
 * Then switch 8 (dip[7]) chooses the mode:
 *
 *   OFF  MIRROR   LEDs 0-6 follow switches 1-7 directly. LED 7 blinks once a
 *                 second -- the heartbeat.
 *   ON   PATTERN  Each time a switch changes, its NUMBER blinks three times
 *                 in binary on the LEDs. Flip switch 3 and you see 011 blink.
 *                 This proves the FPGA saw THAT switch, not merely a switch.
 *
 * ===========================================================================
 * TIMING IS A PARAMETER
 * ===========================================================================
 * The debounce and blink periods are counted in clock cycles and scaled by
 * TICK. On the board TICK is 12,000 (one millisecond at 12 MHz); the bench
 * uses a tiny value so a simulated second takes microseconds. The LOGIC is
 * identical -- only the constant changes -- which is what lets the bench
 * check the real sequencing instead of a sped-up imitation of it.
 */
`default_nettype none

module hydra_fpga_selftest #(
  parameter int unsigned TICK         = 12_000,   // clock cycles per millisecond
  parameter int unsigned CLKS_PER_BIT = 104,      // 12 MHz / 115200
  parameter int unsigned DEBOUNCE_MS  = 10,
  parameter int unsigned STEP_MS      = 125,      // one LED position in the sweep
  parameter int unsigned BLINK_MS     = 150
) (
  input  wire        clk,
  input  wire        rst_n,        // the board's button: pressing it replays the sweep
  input  wire [7:0]  dip,
  output logic [7:0] led,
  input  wire        uart_rx_i,
  output wire        uart_tx_o
);
  // ---- millisecond tick ------------------------------------------------------
  logic [$clog2(TICK+1)-1:0] tick_ctr;
  wire ms = (tick_ctr == ($clog2(TICK+1))'(TICK - 1));
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)  tick_ctr <= '0;
    else         tick_ctr <= ms ? '0 : tick_ctr + 1'b1;

  // ---- switches: synchronise, then debounce ---------------------------------
  // Two flops first: a switch is an asynchronous input like any other, and
  // one flop is a metastability hazard the same as in the JTAG crossing.
  logic [7:0] dip_s1, dip_s2, dip_q, dip_prev;
  logic [7:0] stable_ms [8];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dip_s1 <= '0; dip_s2 <= '0; dip_q <= '0; dip_prev <= '0;
      for (int i = 0; i < 8; i++) stable_ms[i] <= '0;
    end else begin
      dip_s1 <= dip;
      dip_s2 <= dip_s1;
      dip_prev <= dip_q;
      for (int i = 0; i < 8; i++) begin
        // A bit changes only after the raw input has held the new value for
        // DEBOUNCE_MS consecutive milliseconds. A bouncing contact resets
        // the count every time it flickers.
        if (dip_s2[i] == dip_q[i])              stable_ms[i] <= '0;
        else if (ms && stable_ms[i] == 8'(DEBOUNCE_MS - 1)) begin
          dip_q[i] <= dip_s2[i]; stable_ms[i] <= '0;
        end else if (ms)                        stable_ms[i] <= stable_ms[i] + 8'd1;
      end
    end
  end

  wire [7:0] changed = dip_q ^ dip_prev;

  // Which switch changed, lowest number first: only one is reported per
  // event, so two flipped at once produce two events rather than a blend.
  logic [2:0] changed_idx;
  always_comb begin
    changed_idx = '0;
    for (int i = 7; i >= 0; i--) if (changed[i]) changed_idx = 3'(i);
  end

  // ---- the display state machine --------------------------------------------
  typedef enum logic [1:0] { SWEEP, IDLE, BLINK } mode_e;
  mode_e       mode;
  logic [3:0]  sweep_pos;          // 0..15: two passes of eight
  logic [9:0]  ms_ctr;
  logic [2:0]  blink_val;
  logic [2:0]  blink_n;            // half-periods remaining
  logic [9:0]  beat_ms;
  logic        heartbeat;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode <= SWEEP; sweep_pos <= '0; ms_ctr <= '0;
      blink_val <= '0; blink_n <= '0; beat_ms <= '0; heartbeat <= 1'b0;
    end else begin
      if (ms) begin
        beat_ms <= (beat_ms == 10'd499) ? '0 : beat_ms + 10'd1;
        if (beat_ms == 10'd499) heartbeat <= ~heartbeat;
      end

      unique case (mode)
        SWEEP: if (ms) begin
          if (ms_ctr == 10'(STEP_MS - 1)) begin
            ms_ctr <= '0;
            if (sweep_pos == 4'd15) mode <= IDLE;
            else                    sweep_pos <= sweep_pos + 4'd1;
          end else ms_ctr <= ms_ctr + 10'd1;
        end

        IDLE: if (|changed && dip_q[7]) begin
          // Pattern mode: name the switch. Switch numbers are 1-based on
          // the silkscreen, so switch index 2 is shown as 3.
          blink_val <= changed_idx + 3'd1;
          blink_n   <= 3'd6;        // three on, three off
          ms_ctr    <= '0;
          mode      <= BLINK;
        end

        BLINK: if (ms) begin
          if (ms_ctr == 10'(BLINK_MS - 1)) begin
            ms_ctr <= '0;
            if (blink_n == 3'd1) mode <= IDLE;
            blink_n <= blink_n - 3'd1;
          end else ms_ctr <= ms_ctr + 10'd1;
        end

        default: mode <= IDLE;
      endcase
    end
  end

  always_comb begin
    unique case (mode)
      SWEEP:   led = 8'd1 << sweep_pos[2:0];
      BLINK:   led = blink_n[0] ? 8'd0 : {5'd0, blink_val};   // even = on
      default: led = dip_q[7] ? {heartbeat, 7'd0}
                              : {heartbeat, dip_q[6:0]};
    endcase
  end

  // ---- serial port: banner, switch reports, echo ----------------------------
  wire       rx_valid;
  wire [7:0] rx_data;
  hydra_fpga_uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
    .clk(clk), .rst_n(rst_n), .rx_i(uart_rx_i), .valid(rx_valid), .data(rx_data));

  logic       tx_start;
  logic [7:0] tx_data;
  wire        tx_busy;
  hydra_fpga_uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
    .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data),
    .busy(tx_busy), .tx_o(uart_tx_o));

  // Messages are built from a small ROM of fixed text plus two variable
  // characters, so the serial output is exactly predictable in the bench.
  // Packed bits, not a `string`: a string parameter cannot be indexed by the
  // converter this flow uses, and it is not something synthesis would turn
  // into a ROM anyway. A string literal packs its FIRST character into the
  // HIGHEST byte, hence the reversed index below.
  // The line ending is spelled as bytes, not as "\r\n": `\r` is NOT a
  // standard Verilog string escape, and the first version of this banner
  // sent a literal letter r, so a terminal showed "OKr".
  localparam int            BLEN   = 23;
  localparam logic [8*BLEN-1:0] BANNER = {"HYDRA-130 SELFTEST OK", 8'h0D, 8'h0A};

  typedef enum logic [2:0] { T_IDLE, T_BANNER, T_SW, T_ECHO, T_WAIT } tx_e;
  tx_e        tst, tnext;
  logic [4:0] tpos;
  // SWITCH REPORTS ARE STATE, NOT EVENTS. The first version latched one
  // change and dropped any that arrived while a message was still going out;
  // flipping switches during the banner produced one report out of eight,
  // which on a board reads as "seven switches are broken". Now any change
  // just marks the report dirty, and the report sent is a snapshot of ALL
  // eight switches. Changes can merge, but the last report always shows the
  // true current state -- nothing is ever lost.
  //
  //   SW 00100001      switch 1 first, '1' = on; here switches 3 and 8
  logic [7:0] sw_snap;
  logic [7:0] echo_q;
  logic       echo_pend, sw_dirty;

  function automatic logic [7:0] sw_char(input logic [4:0] p, input logic [7:0] snap);
    if (p == 5'd0) return "S";
    if (p == 5'd1) return "W";
    if (p == 5'd2) return " ";
    if (p >= 5'd3 && p <= 5'd10) return snap[p - 5'd3] ? "1" : "0";
    if (p == 5'd11) return 8'h0D;
    return 8'h0A;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tst <= T_BANNER; tnext <= T_IDLE; tpos <= '0; tx_start <= 1'b0; tx_data <= '0;
      sw_snap <= '0; echo_q <= '0;
      echo_pend <= 1'b0; sw_dirty <= 1'b0;
    end else begin
      tx_start <= 1'b0;

      if (rx_valid) begin echo_q <= rx_data; echo_pend <= 1'b1; end

      unique case (tst)
        T_IDLE: begin
          tpos <= '0;
          if (echo_pend)     begin tst <= T_ECHO; echo_pend <= 1'b0; end
          else if (sw_dirty) begin tst <= T_SW; sw_snap <= dip_q; sw_dirty <= 1'b0; end
        end

        T_BANNER: if (!tx_busy && !tx_start) begin
          tx_data  <= BANNER[8*(BLEN - 1 - int'(tpos)) +: 8];
          tx_start <= 1'b1;
          tnext    <= (tpos == 5'(BLEN - 1)) ? T_IDLE : T_BANNER;
          tpos     <= tpos + 5'd1;
          tst      <= T_WAIT;
        end

        T_SW: if (!tx_busy && !tx_start) begin
          tx_data  <= sw_char(tpos, sw_snap);
          tx_start <= 1'b1;
          tnext    <= (tpos == 5'd12) ? T_IDLE : T_SW;
          tpos <= tpos + 5'd1;
          tst  <= T_WAIT;
        end

        T_ECHO: if (!tx_busy && !tx_start) begin
          tx_data  <= echo_q;
          tx_start <= 1'b1;
          tnext    <= T_IDLE;
          tst      <= T_WAIT;
        end

        // One cycle for the transmitter to raise busy before we look again.
        T_WAIT: if (!tx_start && tx_busy) tst <= tnext;

        default: tst <= T_IDLE;
      endcase

      // After the case on purpose: if a switch changes in the very cycle a
      // snapshot is taken, this later assignment wins and another report
      // follows. Placed before the case, that change would be lost.
      if (|changed) sw_dirty <= 1'b1;
    end
  end
endmodule

`default_nettype wire
