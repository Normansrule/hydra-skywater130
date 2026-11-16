// =============================================================================
// tb_i2c_gpio.sv -- hydra_i2c_gpio against its independent model
// =============================================================================
// A bit-banged I2C controller replays common/tb/i2c_gpio_model.py's vectors
// (+vec=<file>): writes, pointer-then-repeated-START reads, traffic to other
// addresses, pad changes. It checks every ACK, every byte read, the GPIO
// outputs after every write, and, on every clock, that the target never pulls
// SDA while the controller owns the line (address and write bits, the
// controller's own ACK) and never pulls it outside a transaction.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_i2c_gpio;
  localparam int NGPIO = 15;
  localparam int Q     = 12;                 // clk cycles per quarter SCL period

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic             scl = 1'b1, m_low = 1'b0; // controller: SCL, SDA pulled low
  wire              t_oe;
  wire              sda = !(m_low || t_oe);  // open drain with a pull-up
  logic [NGPIO-1:0] pads = '0;
  wire  [NGPIO-1:0] gout, goe;

  // the target may drive only in these windows, set by the controller below
  logic             t_may = 1'b0;

  // the host bus side: four banks of memory, read data two cycles after the address
  wire        b_we;
  wire [1:0]  b_bank;
  wire [15:0] b_addr;
  wire [31:0] b_wdata;
  logic [31:0] b_mem [0:4*65536-1];
  logic [31:0] b_r1, b_r2;
  initial for (int i = 0; i < 4*65536; i++) b_mem[i] = 32'd0;
  int bus_writes = 0;
  always @(posedge clk) begin
    if (b_we) begin b_mem[{b_bank, b_addr}] <= b_wdata; bus_writes++; end
    b_r1 <= b_mem[{b_bank, b_addr}]; b_r2 <= b_r1;
  end

  hydra_i2c_gpio #(.ADDR(7'h2A), .NGPIO(NGPIO), .HOST_BUS(1'b1)) dut (
    .clk(clk), .rst_n(rst_n), .scl_i(scl), .sda_i(sda), .sda_oe(t_oe),
    .gpio_in(pads), .mask_rev(32'hC0DE1301), .gpio_out(gout), .gpio_oe(goe), .owner(),
    .bus_we(b_we), .bus_bank(b_bank), .bus_addr(b_addr), .bus_wdata(b_wdata), .bus_rdata(b_r2));

  integer errors = 0, checks = 0, bytes_rd = 0, acks = 0;
  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin errors++; if (errors < 20) $display("FAIL: %s", what); end
  endtask

  always @(posedge clk) if (rst_n && t_oe && !t_may) begin
    errors++;
    if (errors < 20) $display("FAIL: target pulled SDA at %0t, outside an ACK or read bit", $time);
  end

  initial begin #200_000_000; $display("FAIL tb_i2c_gpio: watchdog"); $fatal(1); end

  task automatic quarter(); repeat (Q) @(posedge clk); endtask

  task automatic start_cond();               // from idle or for a repeated START
    m_low = 0; quarter(); scl = 1; quarter();
    m_low = 1; quarter(); scl = 0; quarter();
  endtask
  task automatic stop_cond();
    m_low = 1; quarter(); scl = 1; quarter(); m_low = 0; quarter(); quarter();
  endtask
  // one byte out; returns the target's ACK
  // (hand_over: a read address, after which the target keeps the line)
  task automatic send_byte(input logic [7:0] b, output bit ack, input bit hand_over = 0);
    for (int i = 7; i >= 0; i--) begin
      m_low = !b[i]; quarter(); scl = 1; quarter(); quarter(); scl = 0;
      if (i == 0) t_may = 1;                  // the ACK may start at this fall
      quarter();
    end
    m_low = 0; quarter(); scl = 1; quarter();
    ack = !sda; quarter(); scl = 0; quarter();
    t_may = hand_over && ack;
  endtask
  // one byte in; the controller ACKs it when last == 0
  task automatic recv_byte(input bit last, output logic [7:0] b);
    m_low = 0; t_may = 1;
    for (int i = 7; i >= 0; i--) begin
      quarter(); scl = 1; quarter(); b[i] = sda; quarter(); scl = 0; quarter();
    end
    t_may = 0;                                // the controller's ACK bit
    // the target releases SDA a few clocks after SCL falls: give it time
    // before the controller drives its ACK, as a real controller would
    m_low = !last; quarter(); scl = 1; quarter(); quarter(); scl = 0;
    t_may = !last;                            // may drive the next bit after the fall
    quarter();
  endtask

  int fd, r;
  string op;
  logic [7:0] addr, a8, n, p, b, e;
  logic [31:0] v0, v1;
  bit ack, want_ack;

  initial begin
    string vec;
    if (!$value$plusargs("vec=%s", vec)) begin $display("FAIL: +vec= not given"); $fatal(1); end
    fd = $fopen(vec, "r");
    if (fd == 0) begin $display("FAIL: cannot open %s", vec); $fatal(1); end
    repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
    check(goe == '0 && gout == '0, "GPIO not all inputs and low after reset");

    r = $fscanf(fd, "%s", op);
    while (r == 1) begin
      if (op == "PADS") begin
        r = $fscanf(fd, "%h", v0); pads = v0[NGPIO-1:0];
        repeat (4) @(posedge clk);
      end else if (op == "PINS") begin
        r = $fscanf(fd, "%h %h", v0, v1);
        check(gout == v0[NGPIO-1:0], $sformatf("gpio_out %h, model %h", gout, v0[NGPIO-1:0]));
        check(goe  == v1[NGPIO-1:0], $sformatf("gpio_oe %h, model %h", goe, v1[NGPIO-1:0]));
      end else if (op == "WR") begin
        r = $fscanf(fd, "%h %h %h", addr, want_ack, n);
        start_cond();
        send_byte({addr[6:0], 1'b0}, ack);
        check(ack == want_ack, $sformatf("write to %h: address ACK %0d, expected %0d", addr, ack, want_ack));
        for (int i = 0; i < n; i++) begin
          r = $fscanf(fd, "%h", b);
          if (want_ack) begin
            send_byte(b, ack); acks++;
            check(ack, $sformatf("write to %h: byte %0d not acknowledged", addr, i));
          end
        end
        stop_cond();
      end else if (op == "RD") begin
        r = $fscanf(fd, "%h %h %h %h", addr, want_ack, p, n);
        start_cond();
        send_byte({addr[6:0], 1'b0}, ack);
        check(ack == want_ack, $sformatf("read from %h: address ACK %0d, expected %0d", addr, ack, want_ack));
        if (want_ack && ack) begin
          send_byte(p, ack);
          check(ack, "pointer byte not acknowledged");
          start_cond();                       // repeated START
          send_byte({addr[6:0], 1'b1}, ack, 1'b1);
          check(ack, "read address not acknowledged after a repeated START");
          for (int i = 0; i < n; i++) begin
            r = $fscanf(fd, "%h", e);
            recv_byte(i == n - 1, b); bytes_rd++;
            check(b == e, $sformatf("register %h read %h, model %h", 8'(p + i), b, e));
          end
          t_may = 0;
        end else begin
          for (int i = 0; i < n; i++) r = $fscanf(fd, "%h", e);
        end
        stop_cond();
      end else begin
        $display("FAIL: unknown vector op %s", op); $fatal(1);
      end
      r = $fscanf(fd, "%s", op);
    end
    $fclose(fd);

    if (errors) begin $display("FAIL tb_i2c_gpio: %0d of %0d checks", errors, checks); $fatal(1); end
    $display("PASS tb_i2c_gpio: %0d checks, %0d bytes read, %0d data bytes written, %0d host-bus words written, every ACK, pin and word as the model says",
             checks, bytes_rd, acks, bus_writes);
    $finish;
  end
endmodule
`default_nettype wire
