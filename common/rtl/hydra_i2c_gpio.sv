/*
 * hydra_i2c_gpio.sv
 *
 * HYDRA-130: an I2C target with general-purpose I/O behind it
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY
 * ===========================================================================
 * The OpenFrame chip had 17 pads (27-43) with nothing on them: input buffers
 * off, outputs off. Every pad should do something. Two of them become an I2C
 * target, the rest general-purpose I/O that the I2C target controls, so a
 * board can read straps, light LEDs or drive a peripheral's enable without
 * going through the scheduler's SPI port.
 *
 * ===========================================================================
 * BUS
 * ===========================================================================
 * Standard 7-bit I2C target, no clock stretching, no general call, no 10-bit
 * addresses. SDA is open drain: sda_oe = 1 pulls it low, otherwise the
 * board's pull-up holds it high. SCL is an input only. Both lines are
 * oversampled by clk through two flops, so clk must be at least 10x SCL
 * (100 kHz SCL needs clk >= 1 MHz; the chip runs at MHz rates).
 *
 *   write:  S  ADDR+W  A  ptr  A  d0  A  d1  A ... P      d0 -> reg[ptr], ...
 *   read:   S  ADDR+W  A  ptr  A  Sr ADDR+R A  d0 A  d1 A ... dN NA P
 *
 * The pointer auto-increments after every data byte, written or read. A
 * write to a read-only or unmapped register is acknowledged and ignored;
 * an unmapped register reads 0. Another address is not acknowledged and
 * the target ignores the bus until the next START.
 *
 * ===========================================================================
 * REGISTERS (8 bit)
 * ===========================================================================
 *   0x00 ID        RO  0x48 ("H")
 *   0x01 OUT_LO    RW  gpio_out[7:0]
 *   0x02 OUT_HI    RW  gpio_out[NGPIO-1:8]
 *   0x03 OE_LO     RW  gpio_oe[7:0]     1 = the pad drives OUT
 *   0x04 OE_HI     RW  gpio_oe[NGPIO-1:8]
 *   0x05 IN_LO     RO  pad values [7:0], through a two-flop synchroniser
 *   0x06 IN_HI     RO  pad values [NGPIO-1:8]
 *   0x07 INFO      RO  NGPIO
 *   0x08-0x0B      RO  mask_rev[31:0], most significant byte first: the
 *                      OpenFrame mask revision the padframe supplies, so
 *                      software can tell silicon revisions apart (v3.11)
 *   0x0C HOSTBUS   RO  1 when the host bus below is built (HOST_BUS = 1)
 *   0x0D OWNER     RW  [0] the CPU's UART drives GPIO 0, [1] the CPU's LEDS
 *                      register drives GPIO 1 and up (directions stay OE's);
 *                      0 = this target drives them (v67, the owner output)
 *   0x10 BANK      RW  host bus: [1:0] bank, [7] HOLD: the address does not
 *                      step, so a stream of words goes to one register (a
 *                      load port such as the CPU's program window)
 *   0x11 ADDR_HI   RW  host bus: address [15:8]
 *   0x12 ADDR_LO   RW  host bus: address [7:0]
 *   0x13-0x16 DATA RW  host bus: one 32-bit word, most significant byte
 *                      first. Writing 0x16 writes the word to BANK:ADDR and
 *                      steps ADDR. Reading 0x13 takes a snapshot of the word
 *                      at BANK:ADDR, 0x14-0x16 return the rest of it, and
 *                      sending 0x16 steps ADDR. After 0x16 the pointer
 *                      returns to 0x13, so a long transfer streams words.
 * Reset: OUT = 0, OE = 0, so every GPIO pad is an input until written.
 *
 * The host bus (v3.12) is how a board loads and reads the microcontroller
 * over two wires: it drives the system tile's memory port (bank 3 is its
 * control space: the CPU program, secure boot, ABI headers).
 * ===========================================================================
 */
`default_nettype none

module hydra_i2c_gpio #(
  parameter logic [6:0] ADDR  = 7'h2A,
  parameter int         NGPIO = 15,         // 9 .. 15
  parameter bit         HOST_BUS = 1'b0     // 1: registers 0x10-0x16 drive the bus below
) (
  input  wire              clk,
  input  wire              rst_n,
  input  wire              scl_i,
  input  wire              sda_i,
  output logic             sda_oe,          // 1: pull SDA low
  input  wire  [NGPIO-1:0] gpio_in,
  input  wire  [31:0]      mask_rev,
  output logic [NGPIO-1:0] gpio_out,
  output logic [NGPIO-1:0] gpio_oe,
  output logic [1:0]       owner,           // OWNER (0x0D), for the chip's pad wiring
  // host bus (HOST_BUS = 1): a memory port, read data valid two cycles after bus_addr
  output logic             bus_we,
  output logic [1:0]       bus_bank,
  output logic [15:0]      bus_addr,
  output logic [31:0]      bus_wdata,
  input  wire  [31:0]      bus_rdata
);

  localparam logic [7:0] ID_VALUE = 8'h48;
  localparam int         NHI      = NGPIO - 8;
  localparam logic [7:0] NG8      = NGPIO[7:0];
  localparam logic [NGPIO-1:0] GZ = {NGPIO{1'b0}};

  // ---------------------------------------------------------------------------
  // Synchronisers and bus events
  // ---------------------------------------------------------------------------
  logic [1:0] scl_s, sda_s;
  logic       scl_d, sda_d;
  logic [NGPIO-1:0] in_meta, in_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_s <= 2'b11; sda_s <= 2'b11; scl_d <= 1'b1; sda_d <= 1'b1;
      in_meta <= GZ; in_q <= GZ;
    end else begin
      scl_s <= {scl_s[0], scl_i};
      sda_s <= {sda_s[0], sda_i};
      scl_d <= scl_s[1];
      sda_d <= sda_s[1];
      in_meta <= gpio_in;
      in_q    <= in_meta;
    end
  end

  wire scl = scl_s[1];
  wire sda = sda_s[1];
  wire ev_start = scl && scl_d && sda_d && !sda;    // SDA falls, SCL high
  wire ev_stop  = scl && scl_d && !sda_d && sda;    // SDA rises, SCL high
  wire scl_rise = scl && !scl_d;
  wire scl_fall = !scl && scl_d;

  // ---------------------------------------------------------------------------
  // Register file
  // ---------------------------------------------------------------------------
  logic [7:0] ptr;
  logic       bus_hold;                       // BANK[7]: keep the address fixed
  logic [23:0] wbuf;                         // DATA bytes 0x13-0x15 until 0x16 commits
  logic [23:0] rsnap;                        // the rest of the word read when 0x13 was sent
  // the pointer steps after every data byte; in the bus window it wraps 0x16 -> 0x13
  wire [7:0] ptr_next = (HOST_BUS && ptr == 8'h16) ? 8'h13 : ptr + 8'd1;

  function automatic logic [7:0] rdata(input logic [7:0] a,
                                       input logic [NGPIO-1:0] o,
                                       input logic [NGPIO-1:0] e,
                                       input logic [NGPIO-1:0] i,
                                       input logic [31:0]      mr,
                                       input logic             hold,
                                       input logic [1:0]       bk,
                                       input logic [15:0]      ba,
                                       input logic [7:0]       live,   // bus_rdata[31:24]
                                       input logic [23:0]      snap,   // rsnap[23:0]
                                       input logic [1:0]       own);
    case (a)
      8'h00:   rdata = ID_VALUE;
      8'h01:   rdata = o[7:0];
      8'h02:   rdata = {{(16-NGPIO){1'b0}}, o[NGPIO-1:8]};
      8'h03:   rdata = e[7:0];
      8'h04:   rdata = {{(16-NGPIO){1'b0}}, e[NGPIO-1:8]};
      8'h05:   rdata = i[7:0];
      8'h06:   rdata = {{(16-NGPIO){1'b0}}, i[NGPIO-1:8]};
      8'h07:   rdata = NG8;
      8'h08:   rdata = mr[31:24];
      8'h09:   rdata = mr[23:16];
      8'h0A:   rdata = mr[15:8];
      8'h0B:   rdata = mr[7:0];
      8'h0C:   rdata = {7'd0, HOST_BUS};
      8'h0D:   rdata = {6'd0, own};
      8'h10:   rdata = HOST_BUS ? {hold, 5'd0, bk} : 8'h00;
      8'h11:   rdata = HOST_BUS ? ba[15:8] : 8'h00;
      8'h12:   rdata = HOST_BUS ? ba[7:0] : 8'h00;
      8'h13:   rdata = HOST_BUS ? live : 8'h00;
      8'h14:   rdata = HOST_BUS ? snap[23:16] : 8'h00;
      8'h15:   rdata = HOST_BUS ? snap[15:8] : 8'h00;
      8'h16:   rdata = HOST_BUS ? snap[7:0] : 8'h00;
      default: rdata = 8'h00;
    endcase
  endfunction

  wire [7:0] rd_now = rdata(ptr, gpio_out, gpio_oe, in_q, mask_rev, bus_hold, bus_bank, bus_addr, bus_rdata[31:24], rsnap[23:0], owner);

  // ---------------------------------------------------------------------------
  // Bus state machine
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {S_IDLE, S_RX, S_RXACK, S_TX, S_TXACK} state_e;
  typedef enum logic [1:0] {K_ADDR, K_PTR, K_DATA} kind_e;

  state_e     st;
  kind_e      kind;
  logic [3:0] bitcnt;
  logic [7:0] sh;
  logic       rw, mack;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; kind <= K_ADDR; bitcnt <= 4'd0; sh <= 8'd0;
      rw <= 1'b0; mack <= 1'b0; sda_oe <= 1'b0; ptr <= 8'd0;
      gpio_out <= GZ; gpio_oe <= GZ; owner <= 2'd0;
      bus_we <= 1'b0; bus_bank <= 2'd0; bus_addr <= 16'd0; bus_wdata <= 32'd0;
      wbuf <= 24'd0; rsnap <= 24'd0; bus_hold <= 1'b0;
    end else if (ev_stop) begin
      st <= S_IDLE; sda_oe <= 1'b0; bus_we <= 1'b0;
    end else if (ev_start) begin                    // START or repeated START
      bus_we <= 1'b0;
      st <= S_RX; kind <= K_ADDR; bitcnt <= 4'd0; sda_oe <= 1'b0;
    end else begin
      bus_we <= 1'b0;
      if (bus_we && !bus_hold) bus_addr <= bus_addr + 16'd1;   // the word was written: next one
      case (st)
        S_IDLE: ;

        S_RX: begin
          if (scl_rise && bitcnt != 4'd8) begin
            sh     <= {sh[6:0], sda};
            bitcnt <= bitcnt + 4'd1;
          end else if (scl_fall && bitcnt == 4'd8) begin
            case (kind)
              K_ADDR:
                if (sh[7:1] == ADDR) begin
                  rw <= sh[0]; sda_oe <= 1'b1; st <= S_RXACK;
                end else begin
                  st <= S_IDLE;                     // not us: no ACK
                end
              K_PTR: begin
                ptr <= sh; sda_oe <= 1'b1; st <= S_RXACK;
              end
              default: begin                        // K_DATA
                case (ptr)
                  8'h01: gpio_out[7:0]       <= sh;
                  8'h02: gpio_out[NGPIO-1:8] <= sh[NHI-1:0];
                  8'h03: gpio_oe[7:0]        <= sh;
                  8'h04: gpio_oe[NGPIO-1:8]  <= sh[NHI-1:0];
                  8'h0D: owner               <= sh[1:0];
                  8'h10: if (HOST_BUS) begin bus_bank <= sh[1:0]; bus_hold <= sh[7]; end
                  8'h11: if (HOST_BUS) bus_addr[15:8]  <= sh;
                  8'h12: if (HOST_BUS) bus_addr[7:0]   <= sh;
                  8'h13: if (HOST_BUS) wbuf[23:16]     <= sh;
                  8'h14: if (HOST_BUS) wbuf[15:8]      <= sh;
                  8'h15: if (HOST_BUS) wbuf[7:0]       <= sh;
                  8'h16: if (HOST_BUS) begin            // the word is complete
                    bus_wdata <= {wbuf, sh}; bus_we <= 1'b1;
                  end
                  default: ;                        // read-only or unmapped
                endcase
                ptr <= ptr_next; sda_oe <= 1'b1; st <= S_RXACK;
              end
            endcase
          end
        end

        S_RXACK:
          if (scl_fall) begin                       // end of the ACK clock
            bitcnt <= 4'd0;
            if (kind == K_ADDR && rw) begin         // start sending at once
              sh     <= rd_now;
              sda_oe <= !rd_now[7];
              ptr    <= ptr_next;
              if (HOST_BUS && ptr == 8'h13) rsnap <= bus_rdata[23:0];    // the word being read
              if (HOST_BUS && ptr == 8'h16 && !bus_hold) bus_addr <= bus_addr + 16'd1;  // next word
              st     <= S_TX;
            end else begin
              sda_oe <= 1'b0;
              kind   <= (kind == K_ADDR) ? K_PTR : K_DATA;
              st     <= S_RX;
            end
          end

        S_TX:
          if (scl_fall) begin
            if (bitcnt == 4'd7) begin               // eight bits out: release
              sda_oe <= 1'b0; st <= S_TXACK;
            end else begin
              bitcnt <= bitcnt + 4'd1;
              sh     <= {sh[6:0], 1'b0};
              sda_oe <= !sh[6];
            end
          end

        S_TXACK:
          if (scl_rise) begin
            mack <= !sda;                           // controller's ACK
          end else if (scl_fall) begin
            if (mack) begin
              sh     <= rd_now;
              sda_oe <= !rd_now[7];
              ptr    <= ptr_next;
              if (HOST_BUS && ptr == 8'h13) rsnap <= bus_rdata[23:0];    // the word being read
              if (HOST_BUS && ptr == 8'h16 && !bus_hold) bus_addr <= bus_addr + 16'd1;  // next word
              bitcnt <= 4'd0;
              st     <= S_TX;
            end else begin
              st <= S_IDLE;                         // NACK: done
            end
          end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
