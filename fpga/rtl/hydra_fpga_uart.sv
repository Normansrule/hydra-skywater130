// =============================================================================
// hydra_fpga_uart.sv -- 8N1 UART, receive and transmit
// =============================================================================
// WHY: the FPGA target exists for bench testing, and the one port every board
// in fpga/boards has (except DE10-Lite) is a USB-serial bridge. A PC script
// over that port replaces the TT demoboard's microcontroller.
//
// The receiver samples mid-bit after a start-bit check, and requires the stop
// bit; a framing error drops the byte rather than delivering garbage.
// CLKS_PER_BIT is computed by tools/hydra_bind.py from the board clock, which
// also checks the baud error is under 2 %.
// =============================================================================
`default_nettype none

module hydra_fpga_uart_rx #(
  parameter int CLKS_PER_BIT = 104
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       rx_i,
  output logic       valid,
  output logic [7:0] data
);
  logic [1:0]  sync;
  logic [15:0] cnt;
  logic [3:0]  nbit;
  logic [7:0]  sr;
  logic        busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync <= 2'b11; cnt <= '0; nbit <= '0; sr <= '0; busy <= 1'b0;
      valid <= 1'b0; data <= '0;
    end else begin
      sync  <= {sync[0], rx_i};
      valid <= 1'b0;
      if (!busy) begin
        if (!sync[1]) begin              // start bit edge
          busy <= 1'b1;
          cnt  <= 16'(CLKS_PER_BIT / 2);
          nbit <= 4'd0;
        end
      end else if (cnt != 0) begin
        cnt <= cnt - 16'd1;
      end else begin
        cnt <= 16'(CLKS_PER_BIT - 1);
        if (nbit == 4'd0) begin
          if (sync[1]) busy <= 1'b0;     // glitch, not a start bit
          nbit <= 4'd1;
        end else if (nbit <= 4'd8) begin
          sr   <= {sync[1], sr[7:1]};    // LSB first
          nbit <= nbit + 4'd1;
        end else begin
          busy <= 1'b0;
          if (sync[1]) begin             // valid stop bit
            valid <= 1'b1;
            data  <= sr;
          end
        end
      end
    end
  end
endmodule


module hydra_fpga_uart_tx #(
  parameter int CLKS_PER_BIT = 104
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       start,
  input  logic [7:0] data,
  output logic       busy,
  output logic       tx_o
);
  logic [15:0] cnt;
  logic [3:0]  nbit;
  logic [9:0]  sr;

  assign tx_o = busy ? sr[0] : 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; cnt <= '0; nbit <= '0; sr <= '1;
    end else if (!busy) begin
      if (start) begin
        busy <= 1'b1;
        sr   <= {1'b1, data, 1'b0};
        cnt  <= 16'(CLKS_PER_BIT - 1);
        nbit <= 4'd0;
      end
    end else if (cnt != 0) begin
      cnt <= cnt - 16'd1;
    end else begin
      cnt <= 16'(CLKS_PER_BIT - 1);
      sr  <= {1'b1, sr[9:1]};
      if (nbit == 4'd9) busy <= 1'b0;
      else              nbit <= nbit + 4'd1;
    end
  end
endmodule

`default_nettype wire
