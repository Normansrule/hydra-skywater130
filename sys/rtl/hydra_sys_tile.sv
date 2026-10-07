/*
 * hydra_sys_tile.sv
 *
 * HYDRA-130: the dispatcher, the crossbar and five engines, behind the
 *            TinyTapeout pin interface
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY
 * ===========================================================================
 * tb_mom_system proved the loop closes in hardware with no host writing
 * completions. This puts that same structure behind the TT pins so it runs on
 * an FPGA board at real speed, driven by tools/hydra_host.py over the serial
 * port -- and so the same composition can be hardened later with real engines
 * dropped in where the models are.
 *
 * Contents:
 *   mom_top      the dispatcher, unchanged
 *   mom_xbar     routes dispatches out and completions back (proved)
 *   engines      LATENCY MODELS. Each takes work, waits, reports done. That
 *                is exactly the part of an engine the roofline model claims
 *                to predict, and the only part the calibration loop needs.
 *   hydra_tt_spi + hydra_tt_regs   the same register map as the tile
 *
 * ===========================================================================
 * WHAT CHANGES RELATIVE TO THE TILE
 * ===========================================================================
 * In the tile, the host owns the dispatch handshake and writes completions.
 * Here the crossbar owns both, and the register block becomes an observer:
 *
 *   ACTION.GO   still presents a descriptor            (unchanged)
 *   CTRL.HOLD   stalls dispatch by holding every engine not-ready, which is
 *               the honest hardware equivalent of the tile's back-pressure
 *   COMP        writes are IGNORED -- engines complete their own work. A host
 *               that writes it is reported through the crossbar's error
 *               outputs rather than silently corrupting a calibration sample.
 *   RESULT, CALUPD, BUSY, STATUS   unchanged, and now reflect real engines
 *
 * ui_in[7:6], sampled live, select the engine latency profile:
 *   00  all engines fast          (dispatch should stay with the cheap engine)
 *   01  TPU slow                  (the calibration loop should move away)
 *   10  SIMD slow
 *   11  all engines slow
 * Live rather than strapped, so one bring-up session can watch the loop move
 * the decision in both directions without reprogramming.
 * ===========================================================================
 */
`default_nettype none

module hydra_sys_tile
  import mom_pkg::*;
#(
  parameter int unsigned NTAG = 8,
  parameter int unsigned NENG = 5,
  parameter int unsigned LAT_FAST = 30,
  parameter int unsigned LAT_SLOW = 2000,
  // Engine 2 is the TPU. With REAL_TPU set it is the systolic array from
  // engines/tpu -- real arithmetic, real timing, synthetic operands. With it
  // clear, engine 2 is a latency model like the others, which is what the
  // calibration demonstration needs (the model's latency is switchable; the
  // array's is whatever the work costs).
  parameter bit          REAL_TPU = 1'b0,
  // Engine 1 is the vector unit. Same arrangement as the TPU: real
  // hardware with a pattern generator for operands.
  parameter bit          REAL_SIMD = 1'b0,
  // With this set, engine 2 is the array fed from a scratchpad instead of
  // from a pattern generator: the host puts the operands in memory and the
  // descriptor says where they are. Mutually exclusive with REAL_TPU.
  parameter bit          TPU_FROM_MEM = 1'b0
) (
  input  wire [7:0] ui_in,
  output wire [7:0] uo_out,
  input  wire [7:0] uio_in,
  output wire [7:0] uio_out,
  output wire [7:0] uio_oe,
  input  wire       ena,
  input  wire       clk,
  input  wire       rst_n,

  // The array's result checksum, for a board to display. It must leave the
  // design: with nothing reading it, synthesis removed every multiplier and
  // accumulator and the "TPU build" was 153 LUTs of controller. Measuring
  // the image is what caught it.
  output wire [31:0] dbg_checksum,     // TPU results
  output wire [15:0] dbg_tiles,
  output wire [31:0] dbg_simd_checksum,
  output wire [15:0] dbg_simd_jobs,

  // scratchpad access, used only when TPU_FROM_MEM is set
  input  wire        mem_we,
  input  wire [1:0]  mem_bank,
  input  wire [15:0] mem_addr,
  input  wire [31:0] mem_wdata,
  input  wire [15:0] mem_raddr,
  output wire [31:0] mem_rdata
);

  wire _unused = &{ena, uio_in, ui_in[5:4], ui_in[3], 1'b0};

  // ---------------------------------------------------------------------------
  // Host interface: the same SPI target and register map as the tile.
  // ---------------------------------------------------------------------------
  wire       cs_start, cs_end, cs_active, rx_valid, tx_load, cipo;
  wire [7:0] rx_byte, tx_byte;
  wire [4:0] rx_index;

  hydra_tt_spi u_spi (
    .clk(clk), .rst_n(rst_n),
    .sck_i(ui_in[0]), .copi_i(ui_in[1]), .csn_i(ui_in[2]), .cipo_o(cipo),
    .cs_start(cs_start), .cs_end(cs_end), .cs_active(cs_active),
    .rx_valid(rx_valid), .rx_byte(rx_byte), .rx_index(rx_index),
    .tx_load(tx_load), .tx_byte(tx_byte));

  wire                wd_valid, wd_ready;
  wire [WD_W-1:0]     wd;
  wire                disp_valid, disp_accept;
  wire [2:0]          disp_engine;
  wire [3:0]          disp_tag;
  work_desc_t         disp_wd;
  wire                comp_valid;
  wire [3:0]          comp_tag;
  wire                err_unsupported, err_stale_comp, fence_busy;
  wire [7:0]          err_tag;
  wire [COST_W-1:0]   obs_margin;
  wire [15:0]         obs_cal_updates;
  wire [NTAG-1:0]     obs_tag_busy;

  wire                r_csr_wr, r_csr_priv, r_cal_freeze, r_cal_reset;
  wire [2:0]          r_csr_engine;
  wire [EPARAM_W-1:0] r_csr_data;
  wire [3:0]          r_bw, r_eps, r_esh, r_fence_tag, r_last_tag, r_margin_nib;
  wire [2:0]          r_last_engine;
  wire                r_irq, r_disp_sticky, regs_accept, r_comp_valid;
  wire [3:0]          r_comp_tag;

  hydra_tt_regs #(.NTAG(NTAG)) u_regs (
    .clk(clk), .rst_n(rst_n),
    .cs_start(cs_start), .cs_end(cs_end), .rx_valid(rx_valid),
    .rx_byte(rx_byte), .rx_index(rx_index), .tx_load(tx_load), .tx_byte(tx_byte),
    .wd_valid(wd_valid), .wd_ready(wd_ready), .wd(wd),
    // The register block OBSERVES the dispatch; the crossbar accepts it.
    .disp_valid(disp_valid), .disp_accept(regs_accept),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(r_comp_valid), .comp_tag(r_comp_tag),
    .fence_tag(r_fence_tag), .fence_busy(fence_busy),
    .csr_wr(r_csr_wr), .csr_priv(r_csr_priv), .csr_engine(r_csr_engine),
    .csr_data(r_csr_data), .csr_bw_dma_log2(r_bw), .csr_eps_mem(r_eps),
    .csr_e_shift(r_esh), .csr_cal_freeze(r_cal_freeze), .csr_cal_reset(r_cal_reset),
    .err_unsupported(err_unsupported), .err_tag(err_tag),
    .err_stale_comp(err_stale_comp), .obs_margin(obs_margin),
    .obs_cal_updates(obs_cal_updates), .obs_tag_busy(obs_tag_busy),
    .irq(r_irq), .last_engine(r_last_engine), .disp_sticky(r_disp_sticky),
    .last_tag(r_last_tag), .margin_nib(r_margin_nib));

  // CTRL.HOLD leaves the register block as disp_accept = ~hold. In the tile
  // that wire IS the dispatch handshake; here the crossbar owns the handshake,
  // so the same bit gates engine readiness instead. Same observable effect for
  // the host, honest hardware behaviour underneath.
  wire host_hold = ~regs_accept;

  // ---------------------------------------------------------------------------
  // Dispatcher
  // ---------------------------------------------------------------------------
  mom_top #(.NTAG(NTAG), .QMAX(4)) u_mom (
    .clk(clk), .rst_n(rst_n),
    .wd_valid(wd_valid), .wd_ready(wd_ready), .wd(work_desc_t'(wd)),
    .disp_valid(disp_valid), .disp_accept(disp_accept),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(comp_valid), .comp_tag(comp_tag),
    .fence_tag(r_fence_tag), .fence_busy(fence_busy),
    .csr_wr(r_csr_wr), .csr_priv(r_csr_priv), .csr_engine(r_csr_engine),
    .csr_data(r_csr_data), .csr_bw_dma_log2(r_bw), .csr_eps_mem(r_eps),
    .csr_e_shift(r_esh), .csr_cal_freeze(r_cal_freeze), .csr_cal_reset(r_cal_reset),
    .err_unsupported(err_unsupported), .err_tag(err_tag),
    .err_stale_comp(err_stale_comp), .obs_margin(obs_margin),
    .obs_cal_updates(obs_cal_updates), .obs_tag_busy(obs_tag_busy));

  // ---------------------------------------------------------------------------
  // Crossbar and engines
  // ---------------------------------------------------------------------------
  wire [NENG-1:0]      eng_valid, eng_ready_raw, eng_done, eng_busy;
  wire [WD_W-1:0]      eng_wd;
  wire [NENG*4-1:0]    eng_tag, eng_done_tag;
  wire                 err_bad_engine, err_done_unknown;

  // HOLD stalls every engine, so the dispatcher sees back-pressure exactly as
  // it does on the tile.
  wire [NENG-1:0] eng_ready = eng_ready_raw & {NENG{~host_hold}};

  mom_xbar #(.NENG(NENG), .NTAG(NTAG), .WD_W(WD_W), .TAGW(4), .ENGW(3)) u_xbar (
    .clk(clk), .rst_n(rst_n),
    .disp_valid(disp_valid), .disp_accept(disp_accept),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(comp_valid), .comp_tag(comp_tag),
    .eng_valid(eng_valid), .eng_ready(eng_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(eng_done), .eng_done_tag(eng_done_tag),
    .eng_busy(eng_busy), .err_bad_engine(err_bad_engine),
    .err_done_unknown(err_done_unknown));

  wire _unused_wd = &{eng_wd, r_comp_valid, r_comp_tag, r_irq, r_disp_sticky, 1'b0};

  // ---- engine latency models ------------------------------------------------
  // Profile is live on ui_in[7:6]; see the header.
  wire [1:0] prof = ui_in[7:6];
  wire slow_tpu  = (prof == 2'b01) || (prof == 2'b11);
  wire slow_simd = (prof == 2'b10) || (prof == 2'b11);

  assign dbg_checksum      = tpu_checksum;
  assign dbg_tiles         = TPU_FROM_MEM ? memtpu_tiles : tpu_tiles;
  assign dbg_simd_checksum = simd_checksum;
  assign dbg_simd_jobs     = simd_jobs;

  // ---- the real TPU, when asked for --------------------------------------
  wire [31:0]      tpu_checksum;
  wire [15:0]      tpu_tiles;
  wire             tpu_ready, tpu_done;
  wire [3:0]       tpu_done_tag;

  wire        memtpu_ready, memtpu_done;
  wire [3:0]  memtpu_done_tag;
  wire [15:0] memtpu_tiles;

  generate
    if (TPU_FROM_MEM) begin : g_mem_tpu
      hydra_engine_tpu_dma #(.N(4), .WD_W(WD_W), .TAGW(4), .AW(10), .DEPTH(1024))
      u_memtpu (
        .clk(clk), .rst_n(rst_n),
        .eng_valid(eng_valid[2]), .eng_ready(memtpu_ready), .eng_wd(eng_wd),
        .eng_tag(eng_tag[2*4 +: 4]),
        .eng_done(memtpu_done), .eng_done_tag(memtpu_done_tag),
        .ld_we(mem_we), .ld_bank(mem_bank), .ld_addr(mem_addr[9:0]),
        .ld_data(mem_wdata),
        .c_raddr(mem_raddr[9:0]), .c_rdata(mem_rdata),
        .tiles_done(memtpu_tiles), .last_status());
    end else begin : g_no_mem_tpu
      assign memtpu_ready = 1'b0;
      assign memtpu_done = 1'b0;
      assign memtpu_done_tag = 4'd0;
      assign memtpu_tiles = 16'd0;
      assign mem_rdata = 32'd0;
    end
  endgenerate

  generate
    if (REAL_TPU) begin : g_real_tpu
      hydra_engine_tpu #(.N(4), .WD_W(WD_W), .TAGW(4)) u_tpu (
        .clk(clk), .rst_n(rst_n),
        .eng_valid(eng_valid[2]), .eng_ready(tpu_ready), .eng_wd(eng_wd),
        .eng_tag(eng_tag[2*4 +: 4]),
        .eng_done(tpu_done), .eng_done_tag(tpu_done_tag),
        .checksum(tpu_checksum), .tiles_done(tpu_tiles), .last_status());
    end else begin : g_no_tpu
      assign tpu_ready = 1'b0;
      assign tpu_done = 1'b0;
      assign tpu_done_tag = 4'd0;
      assign tpu_checksum = 32'd0;
      assign tpu_tiles = 16'd0;
    end
  endgenerate

  // ---- the real vector unit, when asked for ------------------------------
  wire [31:0] simd_checksum;
  wire [15:0] simd_jobs;
  wire        simd_ready, simd_done;
  wire [3:0]  simd_done_tag;

  generate
    if (REAL_SIMD) begin : g_real_simd
      hydra_engine_simd #(.N(4), .WD_W(WD_W), .TAGW(4)) u_simd (
        .clk(clk), .rst_n(rst_n),
        .eng_valid(eng_valid[1]), .eng_ready(simd_ready), .eng_wd(eng_wd),
        .eng_tag(eng_tag[1*4 +: 4]),
        .eng_done(simd_done), .eng_done_tag(simd_done_tag),
        .checksum(simd_checksum), .jobs_done(simd_jobs), .last_status());
    end else begin : g_no_simd
      assign simd_ready = 1'b0;
      assign simd_done = 1'b0;
      assign simd_done_tag = 4'd0;
      assign simd_checksum = 32'd0;
      assign simd_jobs = 16'd0;
    end
  endgenerate

  genvar e;
  generate
    for (e = 0; e < NENG; e++) begin : g_eng
      logic [15:0] cnt;
      logic [3:0]  held;
      logic        done_q;

      wire [15:0] lat =
          (e == 2 && slow_tpu)  ? 16'(LAT_SLOW) :
          (e == 1 && slow_simd) ? 16'(LAT_SLOW) : 16'(LAT_FAST + 7 * e);

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          cnt <= '0; held <= '0; done_q <= 1'b0;
        end else begin
          done_q <= 1'b0;
          if (eng_valid[e]) begin
            cnt  <= lat;
            held <= eng_tag[e*4 +: 4];
          end else if (cnt > 16'd1) begin
            cnt <= cnt - 16'd1;
          end else if (cnt == 16'd1) begin
            cnt    <= '0;
            done_q <= 1'b1;
          end
        end
      end

      // Engine 2 is either the array or the model, never both driving.
      if (e == 1) begin : g_eng1_sel
        assign eng_ready_raw[e]       = REAL_SIMD ? simd_ready    : (cnt == 0);
        assign eng_done[e]            = REAL_SIMD ? simd_done     : done_q;
        assign eng_done_tag[e*4 +: 4] = REAL_SIMD ? simd_done_tag : held;
      end else if (e == 2) begin : g_eng2_sel
        assign eng_ready_raw[e]       = REAL_TPU ? tpu_ready    : (cnt == 0);
        assign eng_done[e]            = REAL_TPU ? tpu_done     : done_q;
        assign eng_done_tag[e*4 +: 4] = REAL_TPU ? tpu_done_tag : held;
      end else begin : g_eng_model
        assign eng_ready_raw[e]       = (cnt == 0);
        assign eng_done[e]            = done_q;
        assign eng_done_tag[e*4 +: 4] = held;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Pins. Same shape as the tile's register personality, plus engine activity
  // on the bidirectionals so a logic analyser sees which engine is running.
  // ---------------------------------------------------------------------------
  assign uo_out = {wd_ready, |eng_busy, r_disp_sticky, r_last_engine,
                   r_irq | err_bad_engine | err_done_unknown, cipo};
  assign uio_out = {r_margin_nib[3:1], err_done_unknown,
                    eng_busy[3:0] | {3'b000, eng_busy[4]}};
  assign uio_oe  = 8'hFF;

  wire _unused_cs = &{cs_active, r_margin_nib[0], r_last_tag, 1'b0};

endmodule

`default_nettype wire
