// =============================================================================
// hydra_fpga_tt_harness.sv -- the TT-A tile on any FPGA board, driven from a PC
// =============================================================================
//
// WHY
//   The tile is the only HYDRA block with a complete, silicon-bound top level
//   today. Running that exact RTL on an FPGA gives a bench platform for the
//   calibration loop with real (not testbench) latencies, and a rehearsal of
//   the demoboard bring-up before the shuttle returns. The same PC script
//   (tools/hydra_host.py) that drives this harness is written against the
//   same register map test_regs.py uses.
//
// HOST PROTOCOL (UART 8N1, default 115200)
//   A5 N d0..dN-1   SPI frame of N bytes (0..32) to the register personality
//                   -> 5A N r0..rN-1          (bytes seen on CIPO)
//   C3 M            reset the tile; M=1 register personality, M=0 legacy
//                   -> 3C M
//   96 U            PIN mode: drive ui_in = U as a level
//                   -> 69 uo_out uio_out      (sampled 4 clocks later)
//   97 U            PIN mode: drive ui_in = U for EXACTLY ONE clock, then
//                   return to the last 96 level. The legacy personality shifts
//                   one bit per clock while `shift` is high, so a level held
//                   across a UART round trip would shift hundreds of bits.
//                   -> 69 uo_out uio_out
//   anything else   -> EE cmd
//
// The tile powers up in the REGISTER personality (DEFAULT_REG = 1) so the PC
// script works with no setup. The strap is applied exactly as a demoboard
// would: ui_in[7:4] = 4'hA with CSn high, held through a 16-cycle reset.
//
// SPI timing matches the cocotb driver that test_regs.py verified: mode 0,
// HALF clocks per half period. HALF defaults to 8, inside the tile's clk/8
// limit with margin for the pin synchroniser.
// =============================================================================
`default_nettype none

module hydra_fpga_tt_harness #(
  parameter int CLKS_PER_BIT = 104,
  parameter int HALF         = 8,
  parameter bit DEFAULT_REG  = 1'b1
) (
  input  logic       clk,
  input  logic       rst_n,         // synchronised board reset
  input  logic       uart_rx_i,
  output logic       uart_tx_o,
  output logic [7:0] uo_mirror,
  output logic [7:0] uio_mirror,
  output logic       reg_mode_o
);

  // ---------------------------------------------------------------------------
  // UART
  // ---------------------------------------------------------------------------
  logic       rx_v;
  logic [7:0] rx_d;
  logic       tx_start, tx_busy;
  logic [7:0] tx_d;

  hydra_fpga_uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
    .clk(clk), .rst_n(rst_n), .rx_i(uart_rx_i), .valid(rx_v), .data(rx_d));
  hydra_fpga_uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
    .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_d), .busy(tx_busy), .tx_o(uart_tx_o));

  // ---------------------------------------------------------------------------
  // Tile
  // ---------------------------------------------------------------------------
  logic [7:0] ui_in, uo_out, uio_out, uio_oe;
  logic       tile_rst_n;

  tt_um_hydra_mom u_tile (
    .ui_in(ui_in), .uo_out(uo_out), .uio_in(8'h00), .uio_out(uio_out),
    .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(tile_rst_n));

  assign uo_mirror  = uo_out;
  assign uio_mirror = uio_out;
  wire _unused = &{uio_oe, 1'b0};

  // ---------------------------------------------------------------------------
  // Bridge state
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE, S_ARG, S_DATA, S_RST, S_PINS, S_CS_LO, S_BIT_SET, S_BIT_HI,
    S_CS_HI, S_REPLY, S_PULSE
  } state_e;
  state_e st;

  logic [7:0]  cmd;
  logic [5:0]  n, idx;            // byte count and index (<= 32)
  logic [7:0]  buf_q [32];
  logic [2:0]  bitn;
  logic [15:0] wait_q;
  logic        pin_mode, strap_reg;
  logic [7:0]  pin_ui, pin_level;
  logic        sck, copi, csn;
  logic [5:0]  rep_len, rep_idx;
  logic [7:0]  rep_q [34];
  logic [4:0]  rst_cnt;

  assign reg_mode_o = strap_reg;

  // Tile pins: reset strap, PIN mode, or SPI from the bridge.
  always_comb begin
    if (rst_cnt != 0)       ui_in = strap_reg ? 8'hA4 : 8'h00;
    else if (pin_mode)      ui_in = pin_ui;
    else if (strap_reg)     ui_in = {5'b0, csn, copi, sck};
    // In the legacy personality the SPI idle pattern must NOT reach the pins:
    // idle chip-select is high, and that pin is legacy's `go`. Leaving it
    // there dispatched whatever was in the shift register the moment reset
    // released (caught by tb_fpga_harness, session 179).
    else                    ui_in = 8'h00;
  end
  assign tile_rst_n = rst_n & (rst_cnt == 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; cmd <= '0; n <= '0; idx <= '0; bitn <= '0; wait_q <= '0;
      pin_mode <= 1'b0; strap_reg <= DEFAULT_REG; pin_ui <= '0; pin_level <= '0;
      sck <= 1'b0; copi <= 1'b0; csn <= 1'b1;
      rep_len <= '0; rep_idx <= '0; tx_start <= 1'b0; tx_d <= '0;
      rst_cnt <= 5'd16;
      for (int i = 0; i < 32; i++) buf_q[i] <= '0;
      for (int i = 0; i < 34; i++) rep_q[i] <= '0;
    end else begin
      tx_start <= 1'b0;
      if (rst_cnt != 0) rst_cnt <= rst_cnt - 5'd1;

      case (st)
        S_IDLE: if (rx_v) begin
          cmd <= rx_d;
          if (rx_d == 8'hA5 || rx_d == 8'hC3 || rx_d == 8'h96 || rx_d == 8'h97) st <= S_ARG;
          else begin
            rep_q[0] <= 8'hEE; rep_q[1] <= rx_d; rep_len <= 6'd2; rep_idx <= '0;
            st <= S_REPLY;
          end
        end

        S_ARG: if (rx_v) begin
          case (cmd)
            8'hA5: begin
              n   <= (rx_d > 8'd32) ? 6'd32 : rx_d[5:0];
              idx <= '0;
              pin_mode <= 1'b0;
              st  <= (rx_d == 8'd0) ? S_CS_LO : S_DATA;
            end
            8'hC3: begin
              strap_reg <= rx_d[0];
              pin_mode  <= 1'b0;
              csn <= 1'b1; sck <= 1'b0; copi <= 1'b0;
              rst_cnt   <= 5'd16;
              rep_q[0] <= 8'h3C; rep_q[1] <= {7'd0, rx_d[0]};
              st <= S_RST;
            end
            8'h96: begin
              pin_mode  <= 1'b1;
              pin_ui    <= rx_d;
              pin_level <= rx_d;
              wait_q    <= 16'd4;
              st <= S_PINS;
            end
            default: begin              // 8'h97
              pin_mode <= 1'b1;
              pin_ui   <= rx_d;
              st <= S_PULSE;
            end
          endcase
        end

        S_DATA: if (rx_v) begin
          buf_q[idx] <= rx_d;
          if (idx + 6'd1 == n) begin idx <= '0; st <= S_CS_LO; end
          else idx <= idx + 6'd1;
        end

        S_RST: if (rst_cnt == 0) begin
          rep_len <= 6'd2; rep_idx <= '0; st <= S_REPLY;
        end

        S_PULSE: begin                   // pin_ui has been applied for one edge
          pin_ui <= pin_level;
          wait_q <= 16'd4;
          st     <= S_PINS;
        end

        S_PINS: if (wait_q != 0) wait_q <= wait_q - 16'd1;
                else begin
                  rep_q[0] <= 8'h69; rep_q[1] <= uo_out; rep_q[2] <= uio_out;
                  rep_len <= 6'd3; rep_idx <= '0; st <= S_REPLY;
                end

        // ---- SPI master, mode 0 --------------------------------------------
        S_CS_LO: begin
          if (csn) begin csn <= 1'b0; sck <= 1'b0; wait_q <= 16'(2 * HALF); end
          else if (wait_q != 0) wait_q <= wait_q - 16'd1;
          else if (n == 0) begin wait_q <= 16'(HALF); st <= S_CS_HI; end
          else begin
            bitn <= 3'd7; idx <= '0;
            copi <= buf_q[0][7];
            wait_q <= 16'(HALF);
            st <= S_BIT_SET;
          end
        end

        S_BIT_SET: begin                 // COPI valid, SCK low
          if (wait_q != 0) wait_q <= wait_q - 16'd1;
          else begin
            buf_q[idx] <= {buf_q[idx][6:0], uo_out[0]};   // sample CIPO, shift
            sck    <= 1'b1;
            wait_q <= 16'(HALF);
            st     <= S_BIT_HI;
          end
        end

        S_BIT_HI: begin                  // SCK high
          if (wait_q != 0) wait_q <= wait_q - 16'd1;
          else begin
            sck <= 1'b0;
            wait_q <= 16'(HALF);
            if (bitn != 0) begin
              bitn <= bitn - 3'd1;
              copi <= buf_q[idx][7];     // already shifted: next bit is MSB
              st   <= S_BIT_SET;
            end else if (idx + 6'd1 != n) begin
              bitn <= 3'd7;
              idx  <= idx + 6'd1;
              copi <= buf_q[idx + 6'd1][7];
              st   <= S_BIT_SET;
            end else begin
              st <= S_CS_HI;
            end
          end
        end

        S_CS_HI: begin
          if (wait_q != 0) wait_q <= wait_q - 16'd1;
          else if (!csn) begin csn <= 1'b1; wait_q <= 16'(2 * HALF); end
          else begin
            rep_q[0] <= 8'h5A; rep_q[1] <= {2'b0, n};
            for (int i = 0; i < 32; i++) rep_q[i + 2] <= buf_q[i];
            rep_len <= n + 6'd2; rep_idx <= '0;
            st <= S_REPLY;
          end
        end

        S_REPLY: begin
          if (!tx_busy && !tx_start) begin
            if (rep_idx == rep_len) st <= S_IDLE;
            else begin
              tx_d     <= rep_q[rep_idx];
              tx_start <= 1'b1;
              rep_idx  <= rep_idx + 6'd1;
            end
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
