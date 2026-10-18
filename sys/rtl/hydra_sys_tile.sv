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
  // ONE PERSONALITY PER ENGINE (audit R1, 2026-10-11). Each engine's ready,
  // done and done-tag come from exactly one source, chosen here. Until then
  // this was three overlapping flags (REAL_TPU, TPU_FROM_MEM, REAL_SIMD), and
  // the selector for engine 2 looked only at REAL_TPU: with TPU_FROM_MEM the
  // scheduler took its completions from the LATENCY MODEL, retiring jobs
  // ~44 cycles in while the array was still computing
  // (sys/tb/tb_sys_tile_mem.sv shows it).
  //
  // Engine 2, the TPU:
  //   0 MODEL    a latency model: no arithmetic, switchable latency (the
  //              calibration demonstration)
  //   1 PATTERN  the systolic array, operands from a pattern generator
  //   2 MEMORY   the systolic array, operands and results in scratchpads
  // Engine 1, the vector unit:
  //   0 MODEL    a latency model
  //   1 PATTERN  the vector unit, operands from a pattern generator
  // Any other value stops elaboration.
  parameter int unsigned TPU_ENGINE  = 0,
  parameter int unsigned SIMD_ENGINE = 0,
  // Engine 5, the GPU (only with NENG = 6, the SkyWater chip's count):
  //   0 MODEL    a latency model
  //   1 PIXELSTORM  sys/rtl/hydra_engine_gpu.sv, loaded over the memory port:
  //              bank 3, address [15:14] = 0 its global memory (word [11:0]),
  //              1 its program (word [9:0]), 2 its kernel parameters ([3:0]),
  //              3 its launch shape (0 grid, 1 block);
  //              mem_raddr[15:14] = 2 reads its global memory back
  parameter int unsigned GPU_ENGINE  = 0,
  // Descriptor ABI version 2 (sys/rtl/hydra_abi_v2.sv), chip only:
  //   0  version 1: every engine eligible, the tile's behaviour
  //   1  every descriptor needs the 64-bit header loaded first over the
  //      memory port, bank 3, address [15:14] = 3: offset 2 header [31:0],
  //      3 header [63:32], 4 a context write {owned[24], id[23:16],
  //      epoch[15:0]}, 5 the healthy-engine mask. mem_raddr[15:14] = 3
  //      reads {refusals[15:0], 8'b0, last refusal code[3:0]}. A refusal
  //      also reaches the host as the register map's error with the tag.
  parameter int unsigned ABI_V2      = 0,
  // Engine 0, the CPU slot (chip only):
  //   0 MODEL    a latency model (the tile's CPU slot is always this)
  //   1 SIXFOLD  sys/rtl/hydra_engine_cpu.sv, the Sixfold RV64 core. Loaded
  //              through the control space (bank 3, [15:14] = 3): offset 6
  //              memory word address, 7 write the word there and step the
  //              address, 8 entry address, 9 cycle limit, 10 register to read
  //              back. mem_raddr[15:14] = 3 with offset 1 reads the memory
  //              word at the address register, 2 the selected register's low
  //              32 bits, 3 its high 32 bits, 4 {status, TOHOST[29:0]}
  parameter int unsigned CPU_ENGINE  = 0
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
  output wire [31:0] mem_rdata,
  output wire        mem_refused     // pulses: the last write was refused (engine owned the banks)
);

  wire _unused = &{ena, uio_in, ui_in[5:4], ui_in[3], 1'b0};

  localparam int unsigned TPU_MODEL = 0, TPU_PATTERN = 1, TPU_MEMORY = 2;
  localparam int unsigned SIMD_MODEL = 0, SIMD_PATTERN = 1;
  localparam bit REAL_TPU     = (TPU_ENGINE == TPU_PATTERN);
  localparam bit TPU_FROM_MEM = (TPU_ENGINE == TPU_MEMORY);
  localparam bit REAL_SIMD    = (SIMD_ENGINE == SIMD_PATTERN);
  localparam bit REAL_GPU     = (GPU_ENGINE == 1) && (NENG > 5);
  generate   // an unknown personality must not quietly become the model
    if (TPU_ENGINE > TPU_MEMORY)   begin : g_bad_tpu_engine  hydra_sys_tile_unknown_TPU_ENGINE  u_bad (); end
    if (SIMD_ENGINE > SIMD_PATTERN) begin : g_bad_simd_engine hydra_sys_tile_unknown_SIMD_ENGINE u_bad (); end
    if (GPU_ENGINE > 1 || (GPU_ENGINE == 1 && NENG < 6)) begin : g_bad_gpu_engine hydra_sys_tile_GPU_ENGINE_needs_NENG_6 u_bad (); end
  endgenerate

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

  wire                wd_valid, wd_ready;          // register map side
  wire [WD_W-1:0]     wd;
  wire                s_wd_valid, s_wd_ready;      // scheduler side
  wire [WD_W-1:0]     s_wd;
  wire [NENG-1:0]     s_elig;
  wire                abi_err;
  wire [7:0]          abi_err_tag;
  wire                m_err_unsupported;
  wire [7:0]          m_err_tag;
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

  hydra_tt_regs #(.NTAG(NTAG), .HOST_COMP(1'b0)) u_regs (   // engines complete themselves
    .clk(clk), .rst_n(rst_n),
    .cs_start(cs_start), .cs_end(cs_end), .rx_valid(rx_valid),
    .rx_byte(rx_byte), .rx_index(rx_index), .tx_load(tx_load), .tx_byte(tx_byte),
    .wd_valid(wd_valid), .wd_ready(wd_ready), .wd(wd),
    // The register block OBSERVES the dispatch; the crossbar accepts it, so
    // the crossbar's handshake is what it records (RTL-02).
    .disp_valid(disp_valid), .disp_accept(regs_accept),
    .disp_fire(disp_valid & disp_accept),
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
  mom_top #(.NENG(NENG), .NTAG(NTAG), .QMAX(4)) u_mom (
    .clk(clk), .rst_n(rst_n),
    .wd_valid(s_wd_valid), .wd_ready(s_wd_ready), .wd(work_desc_t'(s_wd)),
    .eng_elig(s_elig),
    .disp_valid(disp_valid), .disp_accept(disp_accept),
    .disp_engine(disp_engine), .disp_tag(disp_tag), .disp_wd(disp_wd),
    .comp_valid(comp_valid), .comp_tag(comp_tag),
    .fence_tag(r_fence_tag), .fence_busy(fence_busy),
    .csr_wr(r_csr_wr), .csr_priv(r_csr_priv), .csr_engine(r_csr_engine),
    .csr_data(r_csr_data), .csr_bw_dma_log2(r_bw), .csr_eps_mem(r_eps),
    .csr_e_shift(r_esh), .csr_cal_freeze(r_cal_freeze), .csr_cal_reset(r_cal_reset),
    .err_unsupported(m_err_unsupported), .err_tag(m_err_tag),
    .err_stale_comp(err_stale_comp), .obs_margin(obs_margin),
    .obs_cal_updates(obs_cal_updates), .obs_tag_busy(obs_tag_busy));

  // A refusal from either the version-2 front end or the scheduler reaches
  // the host the same way. They cannot coincide: the front end holds a job
  // until the scheduler has dispatched or refused it.
  assign err_unsupported = m_err_unsupported | abi_err;
  assign err_tag         = abi_err ? abi_err_tag : m_err_tag;

  // ---------------------------------------------------------------------------
  // Descriptor ABI version 2
  // ---------------------------------------------------------------------------
  wire        ctl_sel = mem_we && (mem_bank == 2'd3) && (mem_addr[15:14] == 2'd3);
  logic [63:0] hdr_q;
  logic [NENG-1:0] healthy_q;
  logic [3:0]  abi_last_code;
  logic [15:0] abi_refusals;
  wire  [3:0]  abi_code;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hdr_q <= '0; healthy_q <= '1; abi_last_code <= '0; abi_refusals <= '0;
    end else begin
      if (ctl_sel && mem_addr[3:0] == 4'd2) hdr_q[31:0]  <= mem_wdata;
      if (ctl_sel && mem_addr[3:0] == 4'd3) hdr_q[63:32] <= mem_wdata;
      if (ctl_sel && mem_addr[3:0] == 4'd5) healthy_q    <= mem_wdata[NENG-1:0];
      if (abi_err) begin abi_last_code <= abi_code; abi_refusals <= abi_refusals + 16'd1; end
    end
  end
  wire [31:0] abi_status = {abi_refusals, 12'd0, abi_last_code};

  // ---- CPU slot controls ---------------------------------------------------
  localparam bit REAL_CPU = (CPU_ENGINE == 1);
  logic [13:0] cpu_addr_q;
  logic [4:0]  cpu_reg_q;
  wire         cpu_wr = ctl_sel && mem_addr[3:0] == 4'd7;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin cpu_addr_q <= '0; cpu_reg_q <= '0; end
    else begin
      if (ctl_sel && mem_addr[3:0] == 4'd6) cpu_addr_q <= mem_wdata[13:0];
      else if (cpu_wr)                       cpu_addr_q <= cpu_addr_q + 14'd1;
      if (ctl_sel && mem_addr[3:0] == 4'd10) cpu_reg_q <= mem_wdata[4:0];
    end
  end
  wire        cpu_ready, cpu_done;
  wire [3:0]  cpu_done_tag;
  wire [1:0]  cpu_status;
  wire [63:0] cpu_tohost, cpu_dbg;
  wire [31:0] cpu_rdata;
  generate
    if (REAL_CPU) begin : g_real_cpu
      hydra_engine_cpu #(.TAGW(4)) u_cpu (
        .clk(clk), .rst_n(rst_n),
        .eng_valid(eng_valid[0]), .eng_ready(cpu_ready), .eng_wd(eng_wd), .eng_tag(eng_tag[3:0]),
        .eng_done(cpu_done), .eng_done_tag(cpu_done_tag), .job_status(cpu_status), .tohost(cpu_tohost),
        .ld_we(cpu_wr), .ld_addr(cpu_addr_q), .ld_data(mem_wdata), .ld_refused(),
        .rd_addr(cpu_addr_q), .rd_data(cpu_rdata), .dbg_reg(cpu_reg_q), .dbg_data(cpu_dbg),
        .cfg_we(ctl_sel && (mem_addr[3:0] == 4'd8 || mem_addr[3:0] == 4'd9)), .cfg_addr(mem_addr[0]),
        .cfg_data(mem_wdata), .perf_cycles());
    end else begin : g_no_cpu
      assign cpu_ready = 1'b0; assign cpu_done = 1'b0; assign cpu_done_tag = 4'd0;
      assign cpu_status = 2'd0; assign cpu_tohost = '0; assign cpu_dbg = '0; assign cpu_rdata = '0;
    end
  endgenerate
  logic [31:0] ctl_rdata;
  always_comb begin
    unique case (mem_raddr[3:0])
      4'd1:    ctl_rdata = cpu_rdata;
      4'd2:    ctl_rdata = cpu_dbg[31:0];
      4'd3:    ctl_rdata = cpu_dbg[63:32];
      4'd4:    ctl_rdata = {cpu_status, cpu_tohost[29:0]};
      default: ctl_rdata = abi_status;
    endcase
  end

  generate
    if (ABI_V2 != 0) begin : g_abi_v2
      hydra_abi_v2 #(.NENG(NENG), .NCTX(16)) u_abi (
        .clk(clk), .rst_n(rst_n),
        .in_valid(wd_valid), .in_ready(wd_ready), .in_hdr(hdr_q), .in_body(wd),
        .out_valid(s_wd_valid), .out_ready(s_wd_ready), .out_body(s_wd), .out_elig(s_elig),
        .sched_done((disp_valid && disp_accept) || m_err_unsupported),
        .err_valid(abi_err), .err_code(abi_code), .err_tag(abi_err_tag),
        .ctx_we(ctl_sel && mem_addr[3:0] == 4'd4), .ctx_id(mem_wdata[23:16]),
        .ctx_owned(mem_wdata[24]), .ctx_epoch(mem_wdata[15:0]), .healthy(healthy_q));
    end else begin : g_abi_v1
      assign s_wd_valid = wd_valid;
      assign wd_ready   = s_wd_ready;
      assign s_wd       = wd;
      assign s_elig     = '1;
      assign abi_err    = 1'b0;
      assign abi_code   = 4'd0;
      assign abi_err_tag = 8'd0;
    end
  endgenerate

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
  wire        gpu_ready, gpu_done, gpu_refused;
  wire [3:0]  gpu_done_tag;
  wire [31:0] gpu_rdata;
  wire [31:0] tpu_m_rdata;
  wire        tpu_m_refused;
  // the memory port is shared: bank 3 belongs to the GPU when there is one
  assign mem_rdata   = (mem_raddr[15:14] == 2'd3) ? ctl_rdata
                     : (REAL_GPU && mem_raddr[15:14] == 2'd2) ? gpu_rdata : tpu_m_rdata;
  assign mem_refused = tpu_m_refused | gpu_refused;

  generate
    if (TPU_FROM_MEM) begin : g_mem_tpu
      hydra_engine_tpu_dma #(.N(4), .WD_W(WD_W), .TAGW(4), .AW(10), .DEPTH(1024))
      u_memtpu (
        .clk(clk), .rst_n(rst_n),
        .eng_valid(eng_valid[2]), .eng_ready(memtpu_ready), .eng_wd(eng_wd),
        .eng_tag(eng_tag[2*4 +: 4]),
        .eng_done(memtpu_done), .eng_done_tag(memtpu_done_tag),
        .ld_we(mem_we && !(REAL_GPU && mem_bank == 2'd3)), .ld_bank(mem_bank), .ld_addr(mem_addr[9:0]),
        .ld_data(mem_wdata), .ld_refused(tpu_m_refused),
        .c_raddr(mem_raddr[9:0]), .c_rdata(tpu_m_rdata),
        .tiles_done(memtpu_tiles), .job_status());
    end else begin : g_no_mem_tpu
      assign memtpu_ready = 1'b0;
      assign memtpu_done = 1'b0;
      assign memtpu_done_tag = 4'd0;
      assign memtpu_tiles = 16'd0;
      assign tpu_m_rdata = 32'd0;
      assign tpu_m_refused = 1'b0;
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

  // ---- the GPU, when asked for (chip only) ----------------------------------
  wire        gpu_sel = (mem_bank == 2'd3);
  generate
    if (REAL_GPU) begin : g_real_gpu
      hydra_engine_gpu #(.TAGW(4), .AW(12)) u_gpu (
        .clk(clk), .rst_n(rst_n),
        .eng_valid(eng_valid[5]), .eng_ready(gpu_ready), .eng_wd(eng_wd),
        .eng_tag(eng_tag[5*4 +: 4]),
        .eng_done(gpu_done), .eng_done_tag(gpu_done_tag), .job_status(),
        .prog_we(mem_we && gpu_sel && mem_addr[15:14] == 2'd1), .prog_addr(mem_addr[9:0]), .prog_data(mem_wdata),
        .cons_we(mem_we && gpu_sel && mem_addr[15:14] == 2'd2), .cons_addr(mem_addr[3:0]), .cons_data(mem_wdata),
        .cfg_we(mem_we && gpu_sel && mem_addr[15:14] == 2'd3 && mem_addr[3:1] == 3'd0),
        .cfg_addr(mem_addr[0]), .cfg_data(mem_wdata[15:0]),
        .ld_we(mem_we && gpu_sel && mem_addr[15:14] == 2'd0), .ld_addr(mem_addr[11:0]), .ld_data(mem_wdata),
        .ld_refused(gpu_refused), .rd_addr(mem_raddr[11:0]), .rd_data(gpu_rdata),
        .perf_cycles());
    end else begin : g_no_gpu
      assign gpu_ready = 1'b0;
      assign gpu_done = 1'b0;
      assign gpu_done_tag = 4'd0;
      assign gpu_refused = 1'b0;
      assign gpu_rdata = 32'd0;
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

      // Each engine's handshake comes from its one personality, all three
      // signals from the same source.
      if (e == 0) begin : g_eng0_sel
        assign eng_ready_raw[e]       = REAL_CPU ? cpu_ready    : (cnt == 0);
        assign eng_done[e]            = REAL_CPU ? cpu_done     : done_q;
        assign eng_done_tag[e*4 +: 4] = REAL_CPU ? cpu_done_tag : held;
      end else if (e == 1) begin : g_eng1_sel
        assign eng_ready_raw[e]       = REAL_SIMD ? simd_ready    : (cnt == 0);
        assign eng_done[e]            = REAL_SIMD ? simd_done     : done_q;
        assign eng_done_tag[e*4 +: 4] = REAL_SIMD ? simd_done_tag : held;
      end else if (e == 2) begin : g_eng2_sel
        assign eng_ready_raw[e]       = TPU_FROM_MEM ? memtpu_ready    : REAL_TPU ? tpu_ready    : (cnt == 0);
        assign eng_done[e]            = TPU_FROM_MEM ? memtpu_done     : REAL_TPU ? tpu_done     : done_q;
        assign eng_done_tag[e*4 +: 4] = TPU_FROM_MEM ? memtpu_done_tag : REAL_TPU ? tpu_done_tag : held;
      end else if (e == 5) begin : g_eng5_sel
        assign eng_ready_raw[e]       = REAL_GPU ? gpu_ready    : (cnt == 0);
        assign eng_done[e]            = REAL_GPU ? gpu_done     : done_q;
        assign eng_done_tag[e*4 +: 4] = REAL_GPU ? gpu_done_tag : held;
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
