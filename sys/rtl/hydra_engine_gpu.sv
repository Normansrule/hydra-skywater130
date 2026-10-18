/*
 * hydra_engine_gpu.sv -- the Pixelstorm GPU behind the HYDRA engine contract
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT THIS IS, AND WHAT IT IS NOT YET
 * ===========================================================================
 * Pixelstorm (Normansrule/pixelstorm-gpu @ 4801c8c, MIT, ext/pixelstorm-gpu, a submodule)
 * is a SIMT GPU: 2 streaming multiprocessors x 4 warps x 8 lanes, a
 * CUDA-style ISA, a host port for the program and the kernel parameters,
 * launch(grid, block), done, and ONE global-memory channel. This file puts
 * that channel on a HYDRA scratchpad bank and gives the whole thing the
 * engine contract every other HYDRA engine has:
 *
 *   eng_valid/eng_ready/eng_wd/eng_tag   take a job (one descriptor)
 *   eng_done/eng_done_tag/job_status     report it, once, after the last
 *                                        global write is in the bank
 *   ld_*                                 the host fills the bank between jobs
 *   rd_*                                 the host reads results back
 *   prog_*, cons_*, cfg_*                the host loads the kernel and its launch shape
 *
 * It is the engine, not the dispatcher slot. Giving it a sixth slot in the
 * cost model (ENG_N = 6, ABI version 2) is a separate change; see
 * docs/architecture/heterogeneous-system.md.
 *
 * ===========================================================================
 * THE JOB
 * ===========================================================================
 * The descriptor says how much work there is, for the scheduler's cost
 * model; it does not say how to launch it. The program, the kernel
 * parameters and the launch shape (cfg address 0: grid, blocks to launch;
 * 1: block, threads per block) are loaded beforehand through prog_*, cons_*
 * and cfg_*. (The first version took grid and block from the descriptor's
 * M and N; that tied the cost model's view of the work to one kernel's
 * thread layout, 2026-10-18.) The parameters carry the buffer addresses, as
 * CUDA kernel arguments do.
 *
 * REFUSED, before anything is launched (job_status = ST_REFUSED):
 *   grid  == 0
 *   block == 0, or block > WARPS * LANES (one block must fit one SM)
 *   no program word written since reset
 * A refused job still completes -- eng_done with its tag -- so a host that
 * sent a malformed launch hears about it instead of waiting for ever.
 *
 * ===========================================================================
 * THE MEMORY CHANNEL
 * ===========================================================================
 * Pixelstorm issues one request at a time on its global channel: a 4-word
 * line read, a masked 4-word line write, or a one-word atomic add, and waits
 * for the response. The bank has one port and a registered read, so:
 *
 *   read    four reads on four cycles, the line answered after the last
 *   write   one write per masked word; the response is given only AFTER the
 *           last word has been written -- so when the GPU's dispatcher says
 *           done, every store it made is in the bank
 *   atomic  read, then write old + value, then answer with old
 *
 * An address whose line runs past the end of the bank is not wrapped (the
 * Pixelstorm testbench wraps; a real memory does not): reads return zero,
 * writes are dropped, and the job ends with job_status = ST_RANGE.
 */
`default_nettype none

module hydra_engine_gpu #(
  parameter int unsigned TAGW    = 4,
  parameter int unsigned AW      = 10,
  parameter int unsigned DEPTH   = 1 << AW,
  parameter int unsigned SMS     = 2,
  parameter int unsigned WARPS   = 4,
  parameter int unsigned LANES   = 8,
  parameter int unsigned IMEM_AW = 10,
  parameter int unsigned CONST_AW = 4
) (
  input  wire              clk,
  input  wire              rst_n,

  // ---- engine port ---------------------------------------------------------
  input  wire              eng_valid,
  output logic             eng_ready,
  input  wire [127:0]      eng_wd,
  input  wire [TAGW-1:0]   eng_tag,
  output logic             eng_done,
  output logic [TAGW-1:0]  eng_done_tag,
  output logic [1:0]       job_status,

  // ---- kernel load (between jobs) ------------------------------------------
  input  wire                 prog_we,
  input  wire [IMEM_AW-1:0]   prog_addr,
  input  wire [31:0]          prog_data,
  input  wire                 cons_we,
  input  wire [CONST_AW-1:0]  cons_addr,
  input  wire [31:0]          cons_data,
  input  wire                 cfg_we,          // launch shape, between jobs
  input  wire                 cfg_addr,        // 0 grid, 1 block
  input  wire [15:0]          cfg_data,

  // ---- bank load and readback (between jobs) --------------------------------
  input  wire              ld_we,
  input  wire [AW-1:0]     ld_addr,
  input  wire [31:0]       ld_data,
  output logic             ld_refused,     // pulses: a write while the engine owned the bank
  input  wire [AW-1:0]     rd_addr,
  output logic [31:0]      rd_data,        // registered: valid the cycle after rd_addr

  output logic [31:0]      perf_cycles     // GPU cycles of the last job (Pixelstorm's own counter)
);
  localparam logic [1:0] ST_OK = 2'd0, ST_REFUSED = 2'd1, ST_RANGE = 2'd2;
  localparam int unsigned LW = 4;          // Pixelstorm LINE_WORDS

  // ---- job acceptance --------------------------------------------------------
  logic [15:0] wd_grid, wd_block;            // the loaded launch shape

  typedef enum logic [2:0] { E_IDLE, E_LAUNCH, E_RUN, E_DRAIN, E_DONE } est_e;
  est_e est;
  logic prog_loaded;
  logic [TAGW-1:0] tag_q;
  logic range_err;

  assign eng_ready = (est == E_IDLE);
  wire accept  = eng_valid && eng_ready;
  wire malformed = (wd_grid == 16'd0) || (wd_block == 16'd0) ||
                   (wd_block > 16'(WARPS * LANES)) || !prog_loaded;

  // ---- the GPU ---------------------------------------------------------------
  logic        gpu_launch;
  logic [15:0] grid_q, block_q;
  wire         gpu_done, gpu_running;
  wire [31:0]  gpu_cycle;
  wire         m_req_valid;
  wire [1:0]   m_req_op;
  wire [31:0]  m_req_addr;
  wire [LW-1:0]    m_req_wmask;
  wire [LW*32-1:0] m_req_wdata;
  logic            m_resp_valid;
  logic [LW*32-1:0] m_resp_rdata;

  ps_gpu_top #(
    .NUM_SMS(SMS), .NUM_WARPS(WARPS), .WARP_SIZE(LANES),
    .LINE_WORDS(LW), .IMEM_AW(IMEM_AW), .CONST_AW(CONST_AW)
  ) u_gpu (
    .clk(clk), .rst(!rst_n),
    .host_imem_we(prog_we && eng_ready), .host_imem_addr(prog_addr), .host_imem_wdata(prog_data),
    .host_cmem_we(cons_we && eng_ready), .host_cmem_addr(cons_addr), .host_cmem_wdata(cons_data),
    .launch(gpu_launch), .grid_dim(grid_q), .block_dim(block_q),
    .done(gpu_done), .running(gpu_running),
    .perf_instr(), .perf_lanes(), .perf_mem(), .cycle(gpu_cycle),
    .mem_req_valid(m_req_valid), .mem_req_op(m_req_op), .mem_req_addr(m_req_addr),
    .mem_req_wmask(m_req_wmask), .mem_req_wdata(m_req_wdata),
    .mem_resp_valid(m_resp_valid), .mem_resp_rdata(m_resp_rdata));

  // ---- the bank and its one port -----------------------------------------------
  typedef enum logic [2:0] { M_IDLE, M_RD, M_RD_LAST, M_WR, M_AT_RD, M_AT_CAP, M_AT_WR, M_RESP } mst_e;
  mst_e mst;
  logic [1:0]       op_q;
  logic [31:0]      addr_q;
  logic [LW-1:0]    mask_q;
  logic [LW*32-1:0] wdata_q;
  logic [2:0]       w;                     // word index within the line
  logic [31:0]      old_q;

  // a line is in range when all four of its words are inside the bank
  wire line_ok = (m_req_addr < 32'(DEPTH)) && (m_req_addr + 32'(LW) <= 32'(DEPTH));
  wire word_ok = (m_req_addr < 32'(DEPTH));
  logic ok_q;

  wire host_owns = (est == E_IDLE) && !accept;
  wire host_we   = ld_we && host_owns;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ld_refused <= 1'b0;
    else        ld_refused <= ld_we && !host_owns;

  logic          b_we;
  logic [AW-1:0] b_addr;
  logic [31:0]   b_wdata;
  wire  [31:0]   b_rdata;

  always_comb begin
    b_we = 1'b0; b_addr = rd_addr; b_wdata = ld_data;
    if (host_we) begin
      b_we = 1'b1; b_addr = ld_addr; b_wdata = ld_data;
    end else begin
      unique case (mst)
        M_RD:    b_addr = AW'(addr_q + 32'(w));
        M_WR:    begin
                   b_addr  = AW'(addr_q + 32'(w));
                   b_we    = ok_q && mask_q[w[1:0]];
                   b_wdata = wdata_q[w[1:0]*32 +: 32];
                 end
        M_AT_RD: b_addr = AW'(addr_q);
        M_AT_WR: begin b_addr = AW'(addr_q); b_we = ok_q; b_wdata = old_q + wdata_q[31:0]; end
        default: ;
      endcase
    end
  end

  hydra_spram #(.DW(32), .DEPTH(DEPTH), .AW(AW)) u_bank (
    .clk(clk), .we(b_we), .addr(b_addr), .wdata(b_wdata), .rdata(b_rdata));
  assign rd_data = b_rdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mst <= M_IDLE; op_q <= '0; addr_q <= '0; mask_q <= '0; wdata_q <= '0;
      w <= '0; old_q <= '0; ok_q <= 1'b0;
      m_resp_valid <= 1'b0; m_resp_rdata <= '0;
    end else begin
      m_resp_valid <= 1'b0;
      unique case (mst)
        M_IDLE: if (m_req_valid) begin
          op_q <= m_req_op; addr_q <= m_req_addr; mask_q <= m_req_wmask;
          wdata_q <= m_req_wdata; w <= '0; m_resp_rdata <= '0;
          ok_q <= (m_req_op == 2'd2) ? word_ok : line_ok;
          unique case (m_req_op)
            2'd0:    mst <= M_RD;
            2'd1:    mst <= M_WR;
            default: mst <= M_AT_RD;
          endcase
        end
        // reads: address word w this cycle, its data arrives next cycle
        M_RD: begin
          if (w != 3'd0 && ok_q) m_resp_rdata[(w - 3'd1) * 32 +: 32] <= b_rdata;
          if (w == 3'(LW - 1)) mst <= M_RD_LAST;
          w <= w + 3'd1;
        end
        M_RD_LAST: begin
          if (ok_q) m_resp_rdata[(LW - 1) * 32 +: 32] <= b_rdata;
          mst <= M_RESP;
        end
        // writes: one masked word per cycle; answer after the last
        M_WR: begin
          if (w == 3'(LW - 1)) mst <= M_RESP;
          w <= w + 3'd1;
        end
        M_AT_RD:  mst <= M_AT_CAP;         // the old word is on b_rdata next cycle
        M_AT_CAP: begin old_q <= b_rdata; mst <= M_AT_WR; end
        M_AT_WR:  mst <= M_RESP;           // old + value written this cycle
        M_RESP: begin
          if (op_q == 2'd2) m_resp_rdata <= {{(LW-1)*32{1'b0}}, ok_q ? old_q : 32'd0};
          m_resp_valid <= 1'b1;
          mst <= M_IDLE;
        end
        default: mst <= M_IDLE;
      endcase
    end
  end

  // ---- job sequencing --------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      est <= E_IDLE; prog_loaded <= 1'b0; tag_q <= '0; range_err <= 1'b0;
      wd_grid <= '0; wd_block <= '0;
      gpu_launch <= 1'b0; grid_q <= '0; block_q <= '0;
      eng_done <= 1'b0; eng_done_tag <= '0; job_status <= ST_OK; perf_cycles <= '0;
    end else begin
      gpu_launch <= 1'b0;
      eng_done   <= 1'b0;
      if (prog_we && eng_ready) prog_loaded <= 1'b1;
      if (cfg_we && eng_ready) begin
        if (cfg_addr) wd_block <= cfg_data; else wd_grid <= cfg_data;
      end
      if (m_req_valid && mst == M_IDLE &&
          !((m_req_op == 2'd2) ? word_ok : line_ok)) range_err <= 1'b1;

      unique case (est)
        E_IDLE: if (accept) begin
          tag_q <= eng_tag;
          if (malformed) begin
            eng_done <= 1'b1; eng_done_tag <= eng_tag; job_status <= ST_REFUSED;
          end else begin
            grid_q <= wd_grid; block_q <= wd_block; range_err <= 1'b0;
            gpu_launch <= 1'b1;
            est <= E_LAUNCH;
          end
        end
        E_LAUNCH: est <= E_RUN;            // the dispatcher clears done on launch
        E_RUN:    if (gpu_done) est <= E_DRAIN;
        // done from the GPU means every block retired; the last store's
        // response was given only after its write, so the bank is complete
        // once the channel is idle
        E_DRAIN:  if (mst == M_IDLE && !m_req_valid) begin
          eng_done <= 1'b1; eng_done_tag <= tag_q;
          job_status <= range_err ? ST_RANGE : ST_OK;
          perf_cycles <= gpu_cycle;
          est <= E_IDLE;
        end
        default:  est <= E_IDLE;
      endcase
    end
  end

  wire _unused = &{gpu_running, eng_wd, 1'b0};
endmodule

`default_nettype wire
