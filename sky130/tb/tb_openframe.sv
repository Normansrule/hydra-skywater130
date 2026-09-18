// =============================================================================
// tb_openframe.sv -- the chip, through its pads
// =============================================================================
// Drives gpio_in / reads gpio_out and gpio_oeb exactly as the padframe will,
// and checks the three things that decide whether a returned chip is usable:
//   1. every pad is an input while reset is low, and stays inert if the
//      connect strap is low -- the state a mis-wired bring-up board needs;
//   2. with the strap high the tile appears on the pads and answers over SPI;
//   3. the personality locks: pulling the strap low afterwards changes nothing.
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
  always @* begin
    gpio_in[P_CLK]  = clk;
    gpio_in[P_RSTN] = rst_n;
    gpio_in[P_CONN] = conn;
  end

  openframe_project_wrapper dut (
    .vdda(), .vdda1(), .vdda2(), .vssa(), .vssa1(), .vssa2(),
    .vccd(), .vccd1(), .vccd2(), .vssd(), .vssd1(), .vssd2(), .vddio(), .vssio(),
    .porb_h(1'b1), .porb_l(1'b1), .por_l(1'b0), .resetb_h(1'b1), .resetb_l(1'b1),
    .mask_rev(32'h0),
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
    if (gpio_inp_dis[P_FIRST + 30] !== 1'b1) begin
      errors++; $display("FAIL: an unused pad has its input buffer enabled");
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

    if (errors) begin $display("FAIL tb_openframe: %0d errors", errors); $fatal(1); end
    $display("PASS tb_openframe");
    $finish;
  end
endmodule
`default_nettype wire
