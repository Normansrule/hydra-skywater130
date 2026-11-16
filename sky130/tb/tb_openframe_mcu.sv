// =============================================================================
// tb_openframe_mcu.sv -- the microcontroller build of the chip, through its pads
// =============================================================================
// openframe_project_wrapper with MCU = 1: the system tile (scheduler, the
// Sixfold CPU on eight SkyWater 130 SRAM macros with secure boot, TPU, vector
// unit) behind the same 44 pads. Everything goes through pins, as on a board:
//
//   1  I2C (pads 27/28): the target answers, its host bus is built
//   2  I2C host bus: a Sixfold program is written into the CPU's memory
//      through the control space, word by word, address held
//   3  a job before any boot: the CPU is not eligible, nothing runs
//   4  I2C: secure boot of the loaded image -> VERIFIED; the digest read back
//      equals hashlib's (the bench is built with BOOT_GOLDEN from
//      sys/tb/boot_digest.py, not from the RTL)
//   5  SPI (pads 3-5, 11): a scalar job goes to the scheduler, which sends it
//      to the CPU; TOHOST, read back over I2C, equals Sixfold's model
//   6  I2C: a CPU register read is refused (0) after the verified boot
//   +dir=<cpu vector dir>   prog.hex and info.txt from tools/cpu_vectors.mjs
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_openframe_mcu;
  parameter logic [255:0] GOLDEN = 256'd0;
  parameter int           BOOT_WORDS = 2112;          // words hashed from address 0

  localparam int NP = 44;
  localparam int P_CLK = 0, P_RSTN = 1, P_CONN = 2;
  localparam int P_SCK = 3, P_COPI = 4, P_CSN = 5, P_CIPO = 11;
  localparam int P_SCL = 27, P_SDA = 28, P_GPIO = 29;
  localparam int UDIV = 16;                           // the CPU UART's clocks per bit after reset
  localparam int Q = 4;                               // clocks per quarter SCL period
  localparam int HALF = 5;                            // clocks per SPI half period

  logic [NP-1:0] gpio_in;
  wire  [NP-1:0] gpio_out, gpio_oeb, gpio_inp_dis;
  wire  [NP-1:0] dm2, dm1, dm0, ibm, vtr, slw, hld, aen, asl, apo;
  logic clk = 0, rst_n = 0, conn = 1;
  logic sck = 0, copi = 0, csn = 1;
  logic scl = 1, m_low = 0;
  logic [2:0] spare_ui = 3'b000;     // pads 6-8: ui_in[5:3] (v68: read back in PINS)
  logic [7:0] spare_uio = 8'h00;     // pads 19-26: uio_in
  wire  t_low = !gpio_oeb[P_SDA];
  wire  sda   = !(m_low || t_low);
  int   errors = 0;

  always #10 clk = ~clk;                              // 50 MHz in simulation
  initial begin #2_000_000_000; $display("FAIL tb_openframe_mcu: watchdog"); $fatal(1); end

  always @* begin
    gpio_in = '0;
    gpio_in[P_CLK] = clk; gpio_in[P_RSTN] = rst_n; gpio_in[P_CONN] = conn;
    gpio_in[P_SCK] = sck; gpio_in[P_COPI] = copi; gpio_in[P_CSN] = csn;
    gpio_in[P_SCL] = scl; gpio_in[P_SDA] = sda;
    gpio_in[6 +: 3] = spare_ui; gpio_in[19 +: 8] = spare_uio;
  end

  openframe_project_wrapper #(.MCU(1), .MCU_BOOT_GOLDEN(GOLDEN)) dut (
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

  // ---- I2C controller on pads 27/28 -------------------------------------------
  task automatic quarter(); repeat (Q) @(posedge clk); endtask
  task automatic i2c_start(); m_low = 0; quarter(); scl = 1; quarter(); m_low = 1; quarter(); scl = 0; quarter(); endtask
  task automatic i2c_stop();  m_low = 1; quarter(); scl = 1; quarter(); m_low = 0; quarter(); quarter(); endtask
  task automatic i2c_tx(input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin m_low = !b[i]; quarter(); scl = 1; quarter(); quarter(); scl = 0; quarter(); end
    m_low = 0; quarter(); scl = 1; quarter();
    if (sda) begin errors++; $display("FAIL: I2C byte %h not acknowledged", b); end
    quarter(); scl = 0; quarter();
  endtask
  task automatic i2c_rx(input bit last, output logic [7:0] b);
    m_low = 0;
    for (int i = 7; i >= 0; i--) begin quarter(); scl = 1; quarter(); b[i] = sda; quarter(); scl = 0; quarter(); end
    m_low = !last; quarter(); scl = 1; quarter(); quarter(); scl = 0; quarter(); m_low = 0;
  endtask
  task automatic i2c_read_reg(input logic [7:0] a, output logic [7:0] v);
    i2c_start(); i2c_tx({7'h2A, 1'b0}); i2c_tx(a);
    i2c_start(); i2c_tx({7'h2A, 1'b1}); i2c_rx(1'b1, v); i2c_stop();
  endtask
  // host bus: one word to bank:address
  task automatic bus_write(input logic [1:0] bank, input logic [15:0] a, input logic [31:0] w);
    i2c_start(); i2c_tx({7'h2A, 1'b0}); i2c_tx(8'h10);
    i2c_tx({6'd0, bank}); i2c_tx(a[15:8]); i2c_tx(a[7:0]);
    i2c_tx(w[31:24]); i2c_tx(w[23:16]); i2c_tx(w[15:8]); i2c_tx(w[7:0]);
    i2c_stop();
  endtask
  task automatic bus_read(input logic [1:0] bank, input logic [15:0] a, output logic [31:0] w);
    logic [7:0] b0, b1, b2, b3;
    i2c_start(); i2c_tx({7'h2A, 1'b0}); i2c_tx(8'h10);
    i2c_tx({1'b1, 5'd0, bank}); i2c_tx(a[15:8]); i2c_tx(a[7:0]); i2c_stop();   // HOLD: no step on read
    repeat (8) @(posedge clk);
    i2c_start(); i2c_tx({7'h2A, 1'b0}); i2c_tx(8'h13);
    i2c_start(); i2c_tx({7'h2A, 1'b1});
    i2c_rx(1'b0, b0); i2c_rx(1'b0, b1); i2c_rx(1'b0, b2); i2c_rx(1'b1, b3); i2c_stop();
    w = {b0, b1, b2, b3};
  endtask
  // control space of the system tile: bank 3, address {2'b11, ..., offset}
  task automatic ctl(input logic [3:0] off, input logic [31:0] w); bus_write(2'd3, {12'hC00, off}, w); endtask
  task automatic ctl_read(input logic [3:0] off, output logic [31:0] w); bus_read(2'd3, {12'hC00, off}, w); endtask

  task automatic i2c_write_reg(input logic [7:0] a, input logic [7:0] v);
    i2c_start(); i2c_tx({7'h2A, 1'b0}); i2c_tx(a); i2c_tx(v); i2c_stop();
  endtask

  // ---- the CPU's console UART on GPIO 0 (pad 29), decoded bit by bit (v67) ----
  wire   uart_pad = gpio_out[P_GPIO];
  wire   uart_drv = !gpio_oeb[P_GPIO];
  string rx_text = "";
  int    rx_errors = 0;
  initial begin : uart_rx
    logic [7:0] b;
    forever begin
      @(negedge uart_pad);
      if (uart_drv) begin
        repeat (UDIV / 2) @(posedge clk);
        if (uart_pad !== 1'b0) rx_errors++;
        else begin
          for (int i = 0; i < 8; i++) begin repeat (UDIV) @(posedge clk); b[i] = uart_pad; end
          repeat (UDIV) @(posedge clk);
          if (uart_pad !== 1'b1) rx_errors++;
          rx_text = $sformatf("%s%c", rx_text, b);
        end
      end
    end
  end

  // ---- SPI host on pads 3, 4, 5 and 11 ---------------------------------------
  logic [7:0] d [24];
  task automatic spi_xfer(input int n);
    csn = 0; repeat (2*HALF) @(posedge clk);
    for (int i = 0; i < n; i++)
      for (int b = 7; b >= 0; b--) begin
        copi = d[i][b]; repeat (HALF) @(posedge clk); sck = 1; repeat (HALF) @(posedge clk); sck = 0;
      end
    repeat (HALF) @(posedge clk); csn = 1; repeat (2*HALF) @(posedge clk);
  endtask
  task automatic spi_wr(input logic [6:0] a, input int n, input logic [127:0] v);
    d[0] = {1'b0, a};
    for (int i = 0; i < n; i++) d[i+1] = v[(n-1-i)*8 +: 8];
    spi_xfer(n + 1);
  endtask

  // ---- the program --------------------------------------------------------------
  string dir;
  reg [7:0]  img [0:65535];
  reg [63:0] want_tohost;
  integer    want_cycles, fd, r;
  reg [31:0] entry;

  function automatic logic [63:0] hdr(input logic [2:0] pol);
    return {4'd2, 2'd0, pol, 8'd1, 16'd7, 8'd0, 8'd0, 15'd0};
  endfunction
  task automatic submit_scalar();
    logic [127:0] desc;
    logic [63:0]  h = hdr(3'd0);
    ctl(4'd2, h[31:0]); ctl(4'd3, h[63:32]);
    desc = '0; desc[127:124] = 4'd0; desc[123:121] = 3'd2; desc[116:101] = 16'd64; desc[100:85] = 16'd1; desc[84:69] = 16'd1;
    spi_wr(7'h01, 16, desc); spi_wr(7'h03, 1, 128'h01);
  endtask

  int cpu_jobs = 0;
  always @(posedge clk) if (dut.g_mcu.u_sys.eng_valid[0]) cpu_jobs++;

  initial begin
    logic [7:0]  v;
    logic [31:0] w, s;
    if (!$value$plusargs("dir=%s", dir)) begin $display("FAIL: +dir= not given"); $fatal(1); end
    for (int a = 0; a < 65536; a++) img[a] = 8'h00;
    $readmemh({dir, "/prog.hex"}, img);
    fd = $fopen({dir, "/info.txt"}, "r"); r = $fscanf(fd, "%h %d %h", want_tohost, want_cycles, entry); $fclose(fd);

    repeat (5) @(posedge clk); rst_n = 1;
    repeat (60) @(posedge clk);

    // 1. the I2C target and its host bus
    i2c_read_reg(8'h00, v); if (v !== 8'h48) begin errors++; $display("FAIL 1: I2C ID %h", v); end
    i2c_read_reg(8'h0C, v); if (v !== 8'h01) begin errors++; $display("FAIL 1: host bus not built (%h)", v); end
    $display("1 I2C target answers, host bus present");

    // 1b. every spare input pad reaches the control space's PINS register
    //     (offset 7: {ena, ui_in[7:3], uio_in}), two patterns so each bit is
    //     seen at 0 and at 1; ui_in[7:6] stay 0 (they select the latency profile)
    for (int k = 0; k < 2; k++) begin
      logic [10:0] pat;
      pat = k ? 11'h25A : 11'h5A5;
      spare_ui = pat[10:8]; spare_uio = pat[7:0];
      repeat (8) @(posedge clk);
      ctl_read(4'd7, w);
      if (w !== {18'd0, 1'b1, 2'b00, pat}) begin
        errors++; $display("FAIL 1b: PINS %h, the pads drive %h", w, {18'd0, 1'b1, 2'b00, pat});
      end
    end
    spare_ui = 3'b000; spare_uio = 8'h00;
    if (errors == 0) $display("1b PINS reads every spare input pad (ui_in[5:3], uio_in) and ena, both levels");

    // 2. the program into the CPU's memory: address register, then a stream of
    //    words to the load window with the bus address held
    ctl(4'd4, {7'd0, 1'b1, 8'd1, 16'd7});            // own context 1, epoch 7
    ctl(4'd6, 32'd0);
    i2c_start(); i2c_tx({7'h2A, 1'b0}); i2c_tx(8'h10);
    i2c_tx(8'h83); i2c_tx(8'hC0); i2c_tx(8'h07);     // bank 3 held, offset 7: write and step
    for (int wd = 0; wd < BOOT_WORDS; wd++) begin
      i2c_tx(img[4*wd+3]); i2c_tx(img[4*wd+2]); i2c_tx(img[4*wd+1]); i2c_tx(img[4*wd]);
    end
    i2c_stop();
    ctl(4'd8, entry);
    $display("2 %0d words loaded over I2C", BOOT_WORDS);

    // 3. before a boot the CPU takes no work
    submit_scalar(); repeat (3000) @(posedge clk);
    if (cpu_jobs != 0) begin errors++; $display("FAIL 3: a job reached the CPU before secure boot"); end
    else $display("3 unbooted CPU: nothing dispatched to it");

    // 4. secure boot
    ctl(4'd11, BOOT_WORDS); ctl(4'd12, 32'd1);
    do begin repeat (500) @(posedge clk); ctl_read(4'd5, s); end while (s[29]);
    if (!s[31]) begin errors++; $display("FAIL 4: boot status %h, not verified", s); end
    for (int i = 0; i < 8; i++) begin
      ctl(4'd13, i); ctl_read(4'd6, w);
      if (w !== GOLDEN[(7 - i) * 32 +: 32]) begin errors++; $display("FAIL 4: digest word %0d %h, hashlib %h", i, w, GOLDEN[(7 - i) * 32 +: 32]); end
    end
    $display("4 secure boot: %s", s[31] ? "VERIFIED, digest equal to hashlib's" : "not verified");

    // 4b. the control space decodes its whole address (v68): a write whose
    //     address bits [13:4] are not 0 changes nothing, and such a read returns 0
    ctl(4'd13, 32'd0);
    bus_write(2'd3, {2'b11, 10'h155, 4'd13}, 32'd5);           // a stray "select digest word 5"
    ctl_read(4'd6, w);
    if (w !== GOLDEN[7 * 32 +: 32]) begin errors++; $display("FAIL 4b: a write with address bits [13:4] = 155 reached the control space"); end
    bus_read(2'd3, {2'b11, 10'h2AA, 4'd6}, w);
    if (w !== 32'd0) begin errors++; $display("FAIL 4b: a read with address bits [13:4] = 2AA returned %h, not 0", w); end
    else $display("4b stray control-space addresses (bits [13:4] not 0) neither write nor read");

    // 5. a scalar job over SPI: the scheduler sends it to the CPU. Before it,
    //    OWNER (0x0D) gives GPIO 0 to the CPU's UART and GPIO 1-14 to its LEDS,
    //    and OE makes those pads outputs (v67)
    i2c_write_reg(8'h0D, 8'h03); i2c_write_reg(8'h03, 8'hFE); i2c_write_reg(8'h04, 8'h7F);
    i2c_read_reg(8'h0D, v); if (v !== 8'h03) begin errors++; $display("FAIL 5: OWNER reads %h", v); end
    rx_text = ""; rx_errors = 0;
    submit_scalar();
    s = 0;
    for (int t = 0; t < 400 && s[29:0] == 0; t++) begin repeat (2000) @(posedge clk); ctl_read(4'd4, s); end
    if (cpu_jobs != 1) begin errors++; $display("FAIL 5: %0d jobs reached the CPU, expected 1", cpu_jobs); end
    if (s[31:30] !== 2'd0 || s[29:0] !== want_tohost[29:0]) begin
      errors++; $display("FAIL 5: CPU status %0d TOHOST %0h, model %0h", s[31:30], s[29:0], want_tohost);
    end else $display("5 scalar job ran on the CPU: TOHOST %0h as Sixfold's model", s[29:0]);

    // 7. what the program printed reached pad 29 as UART frames, equal to the
    //    model's console; its LEDS register reached pads 30-43
    begin : devices
      int f, c, leds;
      string want;
      want = "";
      f = $fopen({dir, "/console.txt"}, "rb");
      if (f != 0) begin
        c = $fgetc(f);
        while (c != -1) begin want = $sformatf("%s%c", want, c[7:0]); c = $fgetc(f); end
        $fclose(f);
        repeat (UDIV * 10 * 20) @(posedge clk);       // the queue drains
        if (rx_errors != 0 || rx_text != want) begin
          errors++; $display("FAIL 7: pad 29 carried %0d bytes (%0d framing errors), the model printed %0d", rx_text.len(), rx_errors, want.len());
        end else $display("7 pad 29 carried the program's %0d printed bytes as UART frames, as the model printed", want.len());
      end
      f = $fopen({dir, "/leds.txt"}, "r");
      if (f != 0) begin
        c = $fscanf(f, "%h", leds); $fclose(f);
        if (gpio_out[P_GPIO + 1 +: 14] !== 14'(leds)) begin
          errors++; $display("FAIL 7: LED pads %h, the model's LEDS %h", gpio_out[P_GPIO + 1 +: 14], 14'(leds));
        end else $display("7 LED pads 30-43 show the program's LEDS %h", gpio_out[P_GPIO + 1 +: 14]);
      end
    end

    // 6. registers locked
    ctl(4'd10, 32'd10); ctl_read(4'd2, w);
    if (w !== 32'd0) begin errors++; $display("FAIL 6: a CPU register read %h after the verified boot", w); end
    else $display("6 CPU registers read 0 after the verified boot");

    if (errors) begin $display("FAIL tb_openframe_mcu: %0d errors", errors); $fatal(1); end
    $display("PASS tb_openframe_mcu: the microcontroller through its pads: program loaded over I2C, secure boot verified with hashlib's digest, a scalar job scheduled over SPI ran on the CPU on SRAM macros");
    $finish;
  end
endmodule
`default_nettype wire
