// =============================================================================
// tb_basys3_selftest.sv -- the Basys 3 bring-up image before it meets a board
// =============================================================================
// Checks what the shared core does not: the upper LEDs and switches, the four
// direction buttons, the centre-button reset, and the display -- banner first,
// then the switches as hex -- by DECODING the multiplexed anode and segment
// lines the way a person's eye integrates them. A display bench that checked
// the hex function alone would miss an anode mapped to the wrong digit.
// Timing scaled down (TICK=4); the logic is the one that ships.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_basys3_selftest;
  // BANNER must outlast one full read of the display (8 ms here) plus the
  // power-on reset, or the bench looks after the banner has gone.
  localparam int TICK = 4, CPB = 8, BANNER = 40;

  logic clk = 0; always #5 clk = ~clk;
  logic btnC = 0, btnU = 0, btnD = 0, btnL = 0, btnR = 0;
  logic [15:0] sw = 16'h0000;
  wire  [15:0] led; wire [6:0] seg; wire dp; wire [3:0] an; wire tx;

  hydra_basys3_selftest #(.TICK(TICK), .CLKS_PER_BIT(CPB), .BANNER_MS(BANNER),
                          .DEBOUNCE_MS(2)) dut (
    .clk(clk), .btnC(btnC), .btnU(btnU), .btnD(btnD), .btnL(btnL), .btnR(btnR),
    .sw(sw), .led(led), .seg(seg), .dp(dp), .an(an), .RsRx(1'b1), .RsTx(tx));

  integer errors = 0, checks = 0;

  // segment pattern -> character, independent of the design's table
  function automatic string decode(input logic [6:0] s_active_low);
    logic [6:0] p; p = ~s_active_low;
    case (p)
      7'h3F: return "0"; 7'h06: return "1"; 7'h5B: return "2"; 7'h4F: return "3";
      7'h66: return "4"; 7'h6D: return "5"; 7'h7D: return "6"; 7'h07: return "7";
      7'h7F: return "8"; 7'h6F: return "9"; 7'h77: return "A"; 7'h7C: return "b";
      7'h39: return "C"; 7'h5E: return "d"; 7'h79: return "E"; 7'h71: return "F";
      7'h76: return "H"; 7'h6E: return "Y"; 7'h50: return "r";
      default: return "?";
    endcase
  endfunction

  // What the display reads, left to right, after watching every digit.
  task automatic read_display(output string text);
    string d [4]; integer k, n, idx;
    logic [3:0] lit;          // ~an held in a 4-bit variable: inside $countones
                              // the expression widens to 32 bits BEFORE the
                              // inversion, and the extra ones count as anodes
    for (k = 0; k < 4; k++) d[k] = "_";
    for (n = 0; n < 8 * TICK; n++) begin
      @(posedge clk); #1;
      lit = ~an;
      if ($countones(lit) != 1) begin
        errors++; $display("FAIL: %0d anodes on at once (an=%b)", $countones(lit), an);
      end
      for (idx = 0; idx < 4; idx++) if (!an[idx]) d[idx] = decode(seg);
    end
    text = {d[3], d[2], d[1], d[0]};
  endtask

  task automatic ms(input integer n); repeat (n * TICK) @(posedge clk); endtask

  string txt;
  initial begin #3_000_000; $display("FAIL: watchdog"); $fatal(1); end

  initial begin
    repeat (20) @(posedge clk);                 // past the power-on reset

    // ---- banner ---------------------------------------------------------------
    read_display(txt);
    if (txt != "HYdr") begin errors++; $display("FAIL banner: display reads \"%s\"", txt); end
    else checks++;
    if (dp !== 1'b1) begin errors++; $display("FAIL: decimal point lit"); end

    // ---- switches as hex --------------------------------------------------------
    ms(BANNER + 2);
    sw = 16'hA5C3; ms(3);
    read_display(txt);
    if (txt != "A5C3") begin errors++; $display("FAIL hex: switches A5C3, display \"%s\"", txt); end
    else checks++;

    // ---- upper LEDs mirror upper switches --------------------------------------
    if (led[15:8] !== 8'hA5) begin errors++; $display("FAIL upper mirror: led %h", led[15:8]); end
    else checks++;

    // ---- each direction button has its own pattern ------------------------------
    begin : btns
      logic [7:0] want [4]; integer b;
      want[0] = 8'b1111_0000; want[1] = 8'b0000_1111;
      want[2] = 8'b1010_1010; want[3] = 8'b0101_0101;
      for (b = 0; b < 4; b++) begin
        {btnU, btnD, btnL, btnR} = 4'b1000 >> b;
        repeat (4) @(posedge clk);
        if (led[15:8] !== want[b]) begin
          errors++; $display("FAIL button %0d: led %b, expected %b", b, led[15:8], want[b]);
        end else checks++;
      end
      {btnU, btnD, btnL, btnR} = 4'b0000;
      repeat (4) @(posedge clk);
    end

    // ---- centre button resets: the banner comes back ---------------------------
    btnC = 1; repeat (6) @(posedge clk); btnC = 0; repeat (20) @(posedge clk);
    read_display(txt);
    if (txt != "HYdr") begin errors++; $display("FAIL reset: display \"%s\" after centre button", txt); end
    else checks++;

    // ---- the shared core is alive: its sweep is on the lower LEDs --------------
    if ($countones(led[7:0]) != 1) begin
      errors++; $display("FAIL: lower LEDs %b during the sweep, expected exactly one lit", led[7:0]);
    end else checks++;

    if (errors) begin $display("FAIL tb_basys3_selftest: %0d errors", errors); $fatal(1); end
    $display("PASS tb_basys3_selftest: %0d checks -- banner, hex display, upper mirror, 4 buttons, reset, core", checks);
    $finish;
  end
endmodule
`default_nettype wire
