// =============================================================================
// tb_openframe.sv -- the chip, through its pads
// =============================================================================
// Drives gpio_in / reads gpio_out and gpio_oeb exactly as the padframe will,
// and checks the three things that decide whether a returned chip is usable:
//   1. every pad is an input while reset is low, and stays inert if the
//      connect strap is low -- the state a mis-wired bring-up board needs;
//   2. with the strap high the tile appears on the pads and answers over SPI;
//   3. the personality locks: pulling the strap low afterwards changes nothing;
//   4. pads 27-43 work: an I2C controller on 27/28 writes and reads the GPIO
//      registers, the GPIO pads drive what was written and read what the
//      board drives, and SDA is only ever pulled low (open drain).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_openframe;
  localparam int NP = 44;
  localparam int P_CLK = 0, P_RSTN = 1, P_CONN = 2, P_FIRST = 3;
  localparam int HALF = 5;      // clocks per SPI half period

  logic [NP-1:0] gpio_in = '0;
  wire  [NP-1:0] gpio_out, gpio_oeb, gpio_inp_dis;
  wire  [NP-1:0] dm2, dm1, dm0, ibm, vtr, slw, hld, aen, asl, apo;
  logic clk = 0, rst_n = 0, conn = 0;
  integer errors = 0;

  always #27.5 clk = ~clk;
  // A broken design must FAIL here, not hang (ci_selftest, 2026-10-11): about
  // twenty times the cycles a passing run needs.
  initial begin repeat (1000000) @(posedge clk); $display("FAIL tb_openframe: watchdog"); $fatal(1); end
  // ---- I2C and GPIO pads (27 SCL, 28 SDA, 29-43 GPIO) ----------------------
  localparam int P_SCL = 27, P_SDA = 28, P_GPIO = 29, NG = 15;
  localparam int Q = 10;                       // clocks per quarter SCL period
  logic          scl = 1'b1, m_low = 1'b0;
  logic [NG-1:0] board = '0;                   // what the board drives on GPIO inputs
  wire           t_low = !gpio_oeb[P_SDA];     // the chip pulls SDA
  wire           sda   = !(m_low || t_low);
  wire  [NG-1:0] g_oe  = ~gpio_oeb[P_GPIO +: NG];
  wire  [NG-1:0] g_out = gpio_out[P_GPIO +: NG];

  always @* begin
    gpio_in[P_CLK]  = clk;
    gpio_in[P_RSTN] = rst_n;
    gpio_in[P_CONN] = conn;
    gpio_in[P_SCL]  = scl;
    gpio_in[P_SDA]  = sda;
    for (int i = 0; i < NG; i++) gpio_in[P_GPIO + i] = g_oe[i] ? g_out[i] : board[i];
  end

  // open drain: whenever the SDA pad drives, it drives 0
  always @(posedge clk) if (t_low && gpio_out[P_SDA] !== 1'b0) begin
    errors++; $display("FAIL: SDA pad driven high at %0t", $time);
  end

  openframe_project_wrapper dut (
    .vdda(), .vdda1(), .vdda2(), .vssa(), .vssa1(), .vssa2(),
    .vccd(), .vccd1(), .vccd2(), .vssd(), .vssd1(), .vssd2(), .vddio(), .vssio(),
    .porb_h(1'b1), .porb_l(1'b1), .por_l(1'b0), .resetb_h(1'b1), .resetb_l(1'b1),
    .mask_rev(32'h13013A01),
    .gpio_in(gpio_in), .gpio_in_h(gpio_in), .gpio_out(gpio_out), .gpio_oeb(gpio_oeb),
    .gpio_inp_dis(gpio_inp_dis), .gpio_ib_mode_sel(ibm), .gpio_vtrip_sel(vtr),
    .gpio_slow_sel(slw), .gpio_holdover(hld), .gpio_analog_en(aen),
    .gpio_analog_sel(asl), .gpio_analog_pol(apo),
    .gpio_dm2(dm2), .gpio_dm1(dm1), .gpio_dm0(dm0),
    .analog_io(), .analog_noesd_io(),
    .gpio_loopback_one({NP{1'b1}}), .gpio_loopback_zero({NP{1'b0}}));

  // ---- SPI over the pads (ui[0]=SCK ui[1]=COPI ui[2]=CSn on pads 3,4,5;
  //      CIPO on uo[0] = pad 11) -------------------------------------------
  localparam int P_SCK = P_FIRST + 0, P_COPI = P_FIRST + 1, P_CSN = P_FIRST + 2;
  localparam int P_CIPO = P_FIRST + 8;

  task automatic spi_byte(input logic [7:0] tx, output logic [7:0] rx);
    for (int i = 7; i >= 0; i--) begin
      gpio_in[P_COPI] = tx[i];
      repeat (HALF) @(posedge clk);
      rx[i] = gpio_out[P_CIPO];
      gpio_in[P_SCK] = 1'b1;
      repeat (HALF) @(posedge clk);
      gpio_in[P_SCK] = 1'b0;
    end
  endtask

  logic [7:0] r0, r1, r2, r3, r4;

  task automatic read_id(output logic [31:0] id);
    gpio_in[P_CSN] = 1'b0;
    repeat (2 * HALF) @(posedge clk);
    spi_byte(8'h80, r0);                 // read address 0x00
    spi_byte(8'h00, r1); spi_byte(8'h00, r2);
    spi_byte(8'h00, r3); spi_byte(8'h00, r4);
    repeat (HALF) @(posedge clk);
    gpio_in[P_CSN] = 1'b1;
    repeat (2 * HALF) @(posedge clk);
    id = {r1, r2, r3, r4};
  endtask

  logic [31:0] id;
  logic [7:0]  rd;

  // ---- an I2C controller on pads 27/28 ---------------------------------------
  task automatic quarter(); repeat (Q) @(posedge clk); endtask
  task automatic i2c_start(); m_low = 0; quarter(); scl = 1; quarter(); m_low = 1; quarter(); scl = 0; quarter(); endtask
  task automatic i2c_stop();  m_low = 1; quarter(); scl = 1; quarter(); m_low = 0; quarter(); quarter(); endtask
  task automatic i2c_tx(input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      m_low = !b[i]; quarter(); scl = 1; quarter(); quarter(); scl = 0; quarter();
    end
    m_low = 0; quarter(); scl = 1; quarter();
    if (sda) begin errors++; $display("FAIL: I2C byte %h not acknowledged", b); end
    quarter(); scl = 0; quarter();
  endtask
  task automatic i2c_rx(output logic [7:0] b);       // one byte, then NACK
    m_low = 0;
    for (int i = 7; i >= 0; i--) begin
      quarter(); scl = 1; quarter(); b[i] = sda; quarter(); scl = 0; quarter();
    end
    quarter(); scl = 1; quarter(); quarter(); scl = 0; quarter();
  endtask
  task automatic i2c_write(input logic [7:0] a, input logic [7:0] v);
    i2c_start(); i2c_tx({7'h2A, 1'b0}); i2c_tx(a); i2c_tx(v); i2c_stop();
  endtask
  task automatic i2c_read(input logic [7:0] a, output logic [7:0] v);
    i2c_start(); i2c_tx({7'h2A, 1'b0}); i2c_tx(a);
    i2c_start(); i2c_tx({7'h2A, 1'b1}); i2c_rx(v); i2c_stop();
  endtask

  initial begin
    // ---- 1. reset: nothing driven --------------------------------------
    gpio_in[P_CSN] = 1'b1;
    conn = 1'b0;
    repeat (4) @(posedge clk);
    if (gpio_oeb !== {NP{1'b1}}) begin
      errors++; $display("FAIL: pads driving during reset, oeb=%h", gpio_oeb);
    end
    rst_n = 1;
    repeat (40) @(posedge clk);
    if (gpio_oeb !== {NP{1'b1}}) begin
      errors++; $display("FAIL: pads driving with the connect strap low, oeb=%h", gpio_oeb);
    end

    // ---- 2. connect, and talk to the tile ------------------------------
    rst_n = 0;
    // The register personality strap lives on ui_in[7:4] = pads 7..10.
    gpio_in[P_FIRST+4] = 1'b0;   // 0xA = 1010
    gpio_in[P_FIRST+5] = 1'b1;
    gpio_in[P_FIRST+6] = 1'b0;
    gpio_in[P_FIRST+7] = 1'b1;
    conn = 1'b1;
    repeat (6) @(posedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    if (gpio_oeb[P_FIRST+8 +: 8] !== 8'h00) begin
      errors++; $display("FAIL: tile outputs not driving after connect, oeb=%h",
                         gpio_oeb[P_FIRST+8 +: 8]);
    end
    if (gpio_oeb[P_FIRST +: 8] !== 8'hFF) begin
      errors++; $display("FAIL: tile input pads are driving, oeb=%h", gpio_oeb[P_FIRST +: 8]);
    end
    if (gpio_inp_dis !== {NP{1'b0}}) begin
      errors++; $display("FAIL: a pad has its input buffer off, inp_dis=%h: every pad has a function", gpio_inp_dis);
    end

    read_id(id);
    $display("chip-level ID read through the pads: %h", id);
    if (id !== 32'h48594D32) begin errors++; $display("FAIL: wrong ID"); end

    // ---- 3. the personality is locked ----------------------------------
    conn = 1'b0;
    repeat (40) @(posedge clk);
    if (gpio_oeb[P_FIRST+8 +: 8] !== 8'h00) begin
      errors++; $display("FAIL: dropping the strap disconnected a locked personality");
    end
    read_id(id);
    if (id !== 32'h48594D32) begin errors++; $display("FAIL: ID lost after strap dropped"); end

    // ---- 4. I2C target and GPIO on pads 27-43 --------------------------
    i2c_read(8'h00, rd);
    if (rd !== 8'h48) begin errors++; $display("FAIL: I2C ID read %h through the pads", rd); end
    i2c_read(8'h07, rd);
    if (rd !== 8'd15) begin errors++; $display("FAIL: I2C INFO read %h, expected 15 GPIO", rd); end
    i2c_read(8'h08, rd);
    if (rd !== 8'h13) begin errors++; $display("FAIL: mask_rev[31:24] read %h over I2C, padframe gives 13", rd); end
    i2c_read(8'h0B, rd);
    if (rd !== 8'h01) begin errors++; $display("FAIL: mask_rev[7:0] read %h over I2C, padframe gives 01", rd); end
    if (g_oe !== '0) begin errors++; $display("FAIL: GPIO pads driving before OE was written"); end
    i2c_write(8'h01, 8'hA5); i2c_write(8'h02, 8'h5A);        // OUT = 0x5AA5 -> 15 bits 0x5AA5
    i2c_write(8'h03, 8'hFF); i2c_write(8'h04, 8'h00);        // OE = 0x00FF
    repeat (4) @(posedge clk);
    if (g_oe !== 15'h00FF) begin errors++; $display("FAIL: GPIO OE on the pads %h, wrote 00ff", g_oe); end
    if (g_out[7:0] !== 8'hA5) begin errors++; $display("FAIL: GPIO pads 29-36 drive %h, wrote a5", g_out[7:0]); end
    board = 15'h2B00;                                         // pads 37-43 are inputs
    repeat (4) @(posedge clk);
    i2c_read(8'h06, rd);
    if (rd !== 8'h2B) begin errors++; $display("FAIL: GPIO IN_HI read %h, the board drives 2b", rd); end
    i2c_read(8'h05, rd);
    if (rd !== 8'hA5) begin errors++; $display("FAIL: GPIO IN_LO read %h, the chip drives a5", rd); end
    i2c_write(8'h03, 8'h00);                                  // back to inputs
    repeat (4) @(posedge clk);
    if (g_oe !== '0) begin errors++; $display("FAIL: GPIO pads still driving after OE cleared"); end

    if (errors) begin $display("FAIL tb_openframe: %0d errors", errors); $fatal(1); end
    $display("PASS tb_openframe: tile over SPI, I2C target and 15 GPIO, every pad used");
    $finish;
  end
endmodule
`default_nettype wire
