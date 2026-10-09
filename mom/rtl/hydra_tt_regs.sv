/*
 * hydra_tt_regs.sv
 *
 * HYDRA-130 - TT-A v2: SPI register map over the complete mom_top interface
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY A v2 AT ALL
 * ===========================================================================
 * v1 (session 144) ties off every mom_top input it could not reach through
 * eight pins: the parameter ROM write port ("retuning is a v2 feature"), the
 * dispatch back-pressure (disp_accept = 1), the fence, calibration freeze and
 * reset, and it reads back only a 4-bit margin nibble. That is the part of
 * the MOM a paper most needs silicon evidence for: that the dispatch policy
 * can be RETUNED after tapeout, and that queueing under back-pressure holds
 * its contract. This block reaches all of it through four pins.
 *
 * ===========================================================================
 * FRAME
 * ===========================================================================
 *   byte 0      command {rw, addr[6:0]}, rw = 1 reads.
 *               CIPO returns STATUS[15:8] during this byte.
 *   bytes 1..N  data, MSB first.
 *
 * Writes COMMIT AT CS RISE and only if exactly LEN data bytes arrived. A short
 * or long frame changes nothing and sets FRAME_ERR. The host is software on a
 * demoboard and will, eventually, drop a byte; a half-written parameter row
 * steering dispatch is the failure this rule exists to prevent.
 *
 * The one exception is WD (128 bits): it shifts straight into the descriptor
 * register to avoid a second 128-bit buffer, so a bad frame clears WD_OK and
 * GO then refuses to present it (GO_ERR). A torn descriptor is never
 * dispatched.
 *
 * Reads are byte-indexed from live values. Every value that can change
 * mid-read changes only in response to something the single SPI host does
 * (GO, COMP, HOLD), so a read is consistent unless the host races itself.
 *
 * ===========================================================================
 * MAP                         len  access
 * ===========================================================================
 *   0x00 ID                     4   RO   0x48594D32 "HYM2"
 *   0x01 WD                    16   RW   descriptor staging
 *   0x02 CTRL                   1   RW   [0] HOLD  (disp_accept = ~HOLD)
 *                                        [1] CAL_FREEZE  [2] CAL_RESET
 *                                        [3] PARAM_LOCK  (sticky to reset)
 *   0x03 ACTION                 1   WO   [0] GO  [1] CLEAR_STICKY
 *   0x04 COMP                   1   WO   [3:0] tag to complete
 *   0x05 STATUS                 2   RO   see status_w below
 *   0x06 RESULT                 6   RO   {engine[2:0], tag[3:0], 0,
 *                                         margin[31:0], err_tag[7:0]}
 *   0x07 LASTWD                16   RO   descriptor as dispatched
 *   0x08 CALUPD                 2   RO   calibration update counter
 *   0x09 BUSY                   2   RO   tag busy bitmap
 *   0x0A FENCE                  1   RW   [3:0] fence tag
 *   0x0B PARAM                  6   WO   {2'b0, engine[2:0], row[42:0]}
 *   0x0C GLOBAL                 2   RW   {4'b0, bw_dma_log2, eps_mem, e_shift}
 *   0x0D INFO                   1   RO   NTAG
 *   other                           read 0, write -> FRAME_ERR
 * ===========================================================================
 */
`default_nettype none

module hydra_tt_regs
  import mom_pkg::*;
#(
  parameter int unsigned NTAG = 8
) (
  input  wire        clk,
  input  wire        rst_n,

  // ---- byte stream from hydra_tt_spi --------------------------------------
  input  wire        cs_start,
  input  wire        cs_end,
  input  wire        rx_valid,
  input  wire  [7:0] rx_byte,
  input  wire  [4:0] rx_index,
  input  wire        tx_load,
  output logic [7:0] tx_byte,

  // ---- mom_top ------------------------------------------------------------
  output wire                wd_valid,
  input  wire                wd_ready,
  output wire  [WD_W-1:0]    wd,
  input  wire                disp_valid,
  output wire                disp_accept,
  input  wire  [2:0]         disp_engine,
  input  wire  [3:0]         disp_tag,
  input  wire  [WD_W-1:0]    disp_wd,
  output logic               comp_valid,
  output logic [3:0]         comp_tag,
  output wire  [3:0]         fence_tag,
  input  wire                fence_busy,
  output logic               csr_wr,
  output wire                csr_priv,
  output logic [2:0]         csr_engine,
  output logic [EPARAM_W-1:0] csr_data,
  output wire  [3:0]         csr_bw_dma_log2,
  output wire  [3:0]         csr_eps_mem,
  output wire  [3:0]         csr_e_shift,
  output wire                csr_cal_freeze,
  output wire                csr_cal_reset,
  input  wire                err_unsupported,
  input  wire  [7:0]         err_tag,
  input  wire                err_stale_comp,
  input  wire  [COST_W-1:0]  obs_margin,
  input  wire  [15:0]        obs_cal_updates,
  input  wire  [NTAG-1:0]    obs_tag_busy,

  // ---- pin-level summaries ------------------------------------------------
  output wire                irq,
  output wire  [2:0]         last_engine,
  output wire                disp_sticky,
  output wire  [3:0]         last_tag,
  output wire  [3:0]         margin_nib
);

  localparam logic [6:0] A_ID = 7'h00, A_WD = 7'h01, A_CTRL = 7'h02,
                         A_ACTION = 7'h03, A_COMP = 7'h04, A_STATUS = 7'h05,
                         A_RESULT = 7'h06, A_LASTWD = 7'h07, A_CALUPD = 7'h08,
                         A_BUSY = 7'h09, A_FENCE = 7'h0A, A_PARAM = 7'h0B,
                         A_GLOBAL = 7'h0C, A_INFO = 7'h0D;

  localparam logic [31:0] ID_VALUE = 32'h48594D32;

  function automatic logic [4:0] reg_len(input logic [6:0] a);
    case (a)
      A_ID:     reg_len = 5'd4;
      A_WD:     reg_len = 5'd16;
      A_CTRL:   reg_len = 5'd1;
      A_ACTION: reg_len = 5'd1;
      A_COMP:   reg_len = 5'd1;
      A_STATUS: reg_len = 5'd2;
      A_RESULT: reg_len = 5'd6;
      A_LASTWD: reg_len = 5'd16;
      A_CALUPD: reg_len = 5'd2;
      A_BUSY:   reg_len = 5'd2;
      A_FENCE:  reg_len = 5'd1;
      A_PARAM:  reg_len = 5'd6;
      A_GLOBAL: reg_len = 5'd2;
      A_INFO:   reg_len = 5'd1;
      default:  reg_len = 5'd0;
    endcase
  endfunction

  function automatic logic writable(input logic [6:0] a);
    writable = (a == A_WD) || (a == A_CTRL) || (a == A_ACTION) || (a == A_COMP) ||
               (a == A_FENCE) || (a == A_PARAM) || (a == A_GLOBAL);
  endfunction

  // ---------------------------------------------------------------------------
  // Frame state
  // ---------------------------------------------------------------------------
  logic       have_cmd, cmd_rd;
  logic [6:0] cmd_addr;
  logic [4:0] n_data;          // data bytes received, saturating at 31
  logic [47:0] wbuf;           // small-register write buffer (<= 6 bytes)

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [WD_W-1:0] wd_q;
  logic            wd_ok;
  logic            hold_q, cal_freeze_q, cal_reset_q, param_lock_q;
  logic [3:0]      fence_q;
  logic [11:0]     global_q;
  logic            pending_q;

  logic            s_disp, s_unsupp, s_stale, s_frame, s_goerr;
  logic [2:0]      r_engine;
  logic [3:0]      r_tag;
  logic [COST_W-1:0] r_margin;
  logic [7:0]      r_errtag;
  logic [WD_W-1:0] r_lastwd;

  wire dispatched = disp_valid & disp_accept;

  // ---------------------------------------------------------------------------
  // Commit decode (evaluated on the cs_end cycle)
  // ---------------------------------------------------------------------------
  wire frame_ok   = have_cmd && !cmd_rd && writable(cmd_addr) &&
                    (n_data == reg_len(cmd_addr));
  wire frame_bad  = have_cmd && !cmd_rd && !frame_ok;
  wire commit     = cs_end && frame_ok;
  wire [7:0] w8   = wbuf[7:0];

  wire do_go      = commit && (cmd_addr == A_ACTION) && w8[0];
  wire do_clear   = commit && (cmd_addr == A_ACTION) && w8[1];
  wire go_accept  = do_go && wd_ok && !pending_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have_cmd <= 1'b0; cmd_rd <= 1'b0; cmd_addr <= 7'd0;
      n_data <= 5'd0; wbuf <= 48'd0;
      wd_q <= '0; wd_ok <= 1'b0;
      hold_q <= 1'b0; cal_freeze_q <= 1'b0; cal_reset_q <= 1'b0; param_lock_q <= 1'b0;
      fence_q <= 4'd0;
      global_q <= {4'd4, 4'd12, 4'd8};      // v1's tie-offs, bit for bit
      pending_q <= 1'b0;
      comp_valid <= 1'b0; comp_tag <= 4'd0;
      csr_wr <= 1'b0; csr_engine <= 3'd0; csr_data <= '0;
      s_disp <= 1'b0; s_unsupp <= 1'b0; s_stale <= 1'b0; s_frame <= 1'b0; s_goerr <= 1'b0;
      r_engine <= 3'd0; r_tag <= 4'd0; r_margin <= '0; r_errtag <= 8'd0;
      r_lastwd <= '0;
    end else begin
      comp_valid <= 1'b0;
      csr_wr     <= 1'b0;

      // ---- frame assembly ---------------------------------------------------
      if (cs_start) begin
        have_cmd <= 1'b0;
        n_data   <= 5'd0;
      end
      if (rx_valid) begin
        if (rx_index == 5'd0) begin
          have_cmd <= 1'b1;
          cmd_rd   <= rx_byte[7];
          cmd_addr <= rx_byte[6:0];
          if (!rx_byte[7] && rx_byte[6:0] == A_WD) wd_ok <= 1'b0;  // WD is being overwritten
        end else if (have_cmd) begin
          if (n_data != 5'd31) n_data <= n_data + 5'd1;
          if (!cmd_rd) begin
            if (cmd_addr == A_WD) wd_q <= {wd_q[WD_W-9:0], rx_byte};
            else                  wbuf <= {wbuf[39:0], rx_byte};
          end
        end
      end

      // ---- commit -----------------------------------------------------------
      if (cs_end) begin
        have_cmd <= 1'b0;
        if (frame_bad) s_frame <= 1'b1;
      end
      if (commit) begin
        case (cmd_addr)
          A_WD:     wd_ok <= 1'b1;
          A_CTRL: begin
            hold_q       <= w8[0];
            cal_freeze_q <= w8[1];
            cal_reset_q  <= w8[2];
            param_lock_q <= param_lock_q | w8[3];
          end
          A_COMP: begin
            comp_valid <= 1'b1;
            comp_tag   <= w8[3:0];
          end
          A_FENCE:  fence_q  <= w8[3:0];
          A_GLOBAL: global_q <= wbuf[11:0];
          A_PARAM: if (!param_lock_q) begin
            csr_wr     <= 1'b1;
            csr_engine <= wbuf[45:43];
            csr_data   <= wbuf[42:0];
          end
          default: ;
        endcase
      end

      // ---- GO handshake -------------------------------------------------------
      // pending holds wd_valid until the MOM takes the descriptor. v1 pulsed
      // wd_valid for one cycle and relied on the host polling `ready` first.
      if (pending_q && wd_ready) pending_q <= 1'b0;
      if (go_accept) begin
        pending_q <= 1'b1;
        s_disp    <= 1'b0;        // v1 semantics: results refer to the last GO
        s_unsupp  <= 1'b0;
      end
      if (do_go && !go_accept) s_goerr <= 1'b1;

      // ---- results ------------------------------------------------------------
      if (dispatched) begin
        r_engine <= disp_engine;
        r_tag    <= disp_tag;
        r_margin <= obs_margin;
        r_lastwd <= disp_wd;
        s_disp   <= 1'b1;
      end
      if (err_unsupported) begin
        s_unsupp <= 1'b1;
        r_errtag <= err_tag;
      end
      if (err_stale_comp) s_stale <= 1'b1;

      if (do_clear) begin
        s_disp <= 1'b0; s_unsupp <= 1'b0; s_stale <= 1'b0;
        s_frame <= 1'b0; s_goerr <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Outputs to the MOM
  // ---------------------------------------------------------------------------
  assign wd_valid        = pending_q;
  assign wd              = wd_q;
  assign disp_accept     = ~hold_q;
  assign fence_tag       = fence_q;
  assign csr_priv        = 1'b1;   // the SPI host is the only master; PARAM_LOCK is the gate
  assign csr_bw_dma_log2 = global_q[11:8];
  assign csr_eps_mem     = global_q[7:4];
  assign csr_e_shift     = global_q[3:0];
  assign csr_cal_freeze  = cal_freeze_q;
  assign csr_cal_reset   = cal_reset_q;

  // ---------------------------------------------------------------------------
  // Status and read path
  // ---------------------------------------------------------------------------
  wire any_busy = |obs_tag_busy;
  wire [15:0] status_w = {wd_ready, any_busy, pending_q, wd_ok,
                          s_disp, s_unsupp, s_stale, s_frame,
                          s_goerr, fence_busy, param_lock_q, hold_q,
                          cal_freeze_q, cal_reset_q, 2'b00};

  logic [15:0] busy16;
  always_comb begin
    busy16 = 16'd0;
    busy16[NTAG-1:0] = obs_tag_busy;
  end

  // Right-justified register value; byte k (k = 0 first) of an L-byte register
  // is rval[(L-1-k)*8 +: 8].
  logic [WD_W-1:0] rval;
  always_comb begin
    case (cmd_addr)
      A_ID:     rval = WD_W'(ID_VALUE);
      A_WD:     rval = wd_q;
      A_CTRL:   rval = WD_W'({param_lock_q, cal_reset_q, cal_freeze_q, hold_q});
      A_STATUS: rval = WD_W'(status_w);
      A_RESULT: rval = WD_W'({r_engine, r_tag, 1'b0, r_margin, r_errtag});
      A_LASTWD: rval = r_lastwd;
      A_CALUPD: rval = WD_W'(obs_cal_updates);
      A_BUSY:   rval = WD_W'(busy16);
      A_FENCE:  rval = WD_W'(fence_q);
      A_GLOBAL: rval = WD_W'(global_q);
      A_INFO:   rval = WD_W'(8'(NTAG));
      default:  rval = '0;
    endcase
  end

  // Byte index of the NEXT byte to send. On the load that follows the command
  // byte, n_data is still 0, so data byte 0 goes out first.
  wire [4:0] len     = reg_len(cmd_addr);
  wire [4:0] k       = n_data;
  wire [6:0] sh      = 7'((len - 5'd1 - k)) * 7'd8;
  wire       in_rng  = have_cmd && cmd_rd && (k < len);

  always_comb begin
    if (!have_cmd)   tx_byte = status_w[15:8];
    else if (in_rng) tx_byte = rval[sh +: 8];
    else             tx_byte = 8'h00;
  end

  wire _unused = &{tx_load, 1'b0};

  // ---------------------------------------------------------------------------
  // Pin summaries
  // ---------------------------------------------------------------------------
  assign irq         = s_disp | s_unsupp | s_stale | s_frame | s_goerr;
  assign last_engine = r_engine;
  assign disp_sticky = s_disp;
  assign last_tag    = r_tag;
  // Log scale: 0 for a tie, otherwise 1 + floor(log2(margin)), saturating at
  // 15. Measured margins in session 179 were 1..145, which a linear top
  // nibble of a 16-bit value (v1's intent) renders as 0 every time.
  logic [3:0] mlog;
  always_comb begin
    mlog = 4'd0;
    for (int b = 0; b < COST_W; b++)
      if (r_margin[b]) mlog = (b >= 14) ? 4'd15 : 4'(b + 1);
  end
  assign margin_nib  = mlog;

endmodule

`default_nettype wire
