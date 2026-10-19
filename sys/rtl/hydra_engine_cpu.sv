/*
 * hydra_engine_cpu.sv -- the Sixfold RV64 core behind the HYDRA engine contract
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sixfold (Normansrule/sixfold-cpu @ a642bd6, MIT, submodule ext/sixfold-cpu)
 * is a 6-stage RV64IM + Zba/Zbb/Zbs + Zknh core. Its own top level loads its
 * memory with $readmemh from a plusarg, which only a simulator can do, and
 * signals the end of a program with HALTED. This wrapper supplies what an
 * engine needs, without changing a line of Sixfold:
 *
 *   ld_*      the host writes the program and its data into the core's
 *             memory, 32 bits at a time, while the core is not running
 *   rd_*      the host reads memory back (registered, one cycle)
 *   dbg_*     the host reads x0..x31 after a job (Sixfold's debug port)
 *   cfg_*     entry address (default 0x2000, Sixfold's reset vector) and a
 *             cycle limit
 *   eng_*     a descriptor starts the program at the entry address; done is
 *             reported once, with the tag, when the core halts (its TOHOST
 *             write has retired: every older instruction has written back)
 *
 * The CPU keeps its own instruction set. HYDRA submits "run the program at
 * this address", not instructions.
 *
 * MEMORY. 64 KiB, unified, read in the same cycle -- the arrangement
 * Sixfold's Riscv64_top uses with its caches off (CACHES_ENABLE = 0), so the
 * core sees exactly the memory its model assumes. On an FPGA or an ASIC this
 * array is the part to replace with a block memory and the caches; that is
 * recorded, not done here.
 *
 * DEVICES. The machine timer (MTIME, MTIMECMP) as in Riscv64_top, so
 * programs that use timer interrupts behave as in the model; every other
 * device address reads 0, as Sixfold's scratchpad does.
 *
 * REFUSED, before the core starts (job_status = 1): no program word
 * written since reset; an entry address that is not word aligned or lies
 * outside the memory. A program that does not halt within the cycle limit
 * is stopped and reported with job_status = 2, and the slot is free again.
 */
`default_nettype none

module hydra_engine_cpu #(
  parameter int unsigned TAGW = 4,
  parameter int unsigned MEM_BYTES = 65536,
  // 0  memory read in the same cycle, no caches (Riscv64_top with
  //    CACHES_ENABLE = 0): the simulation arrangement
  // 1  Sixfold's own instruction and data caches over a line-wide block
  //    memory (its fpga/rtl/Main_Memory.sv, the arrangement its FPGA system
  //    uses): synthesizable, block RAM on an FPGA, SRAM macros on a chip
  parameter bit          CACHED = 1'b0,
  parameter int unsigned MISS_LATENCY = 10
) (
  input  wire              clk,
  input  wire              rst_n,

  input  wire              eng_valid,
  output logic             eng_ready,
  input  wire [127:0]      eng_wd,
  input  wire [TAGW-1:0]   eng_tag,
  output logic             eng_done,
  output logic [TAGW-1:0]  eng_done_tag,
  output logic [1:0]       job_status,     // 0 halted normally, 1 refused, 2 cycle limit
  output logic [63:0]      tohost,         // Sixfold's TOHOST value of the last job

  input  wire              ld_we,
  input  wire [13:0]       ld_addr,        // word address
  input  wire [31:0]       ld_data,
  output logic             ld_refused,
  input  wire [13:0]       rd_addr,
  output logic [31:0]      rd_data,         // one cycle after rd_addr
  input  wire [4:0]        dbg_reg,
  output wire [63:0]       dbg_data,

  input  wire              cfg_we,
  input  wire              cfg_addr,       // 0 entry address, 1 cycle limit
  input  wire [31:0]       cfg_data,

  output logic [31:0]      perf_cycles     // cycles from the core leaving reset to HALTED
);
  localparam logic [63:0] MMIO_BASE     = 64'h0000_0000_1000_0000;
  localparam logic [63:0] MMIO_MTIME    = 64'h0000_0000_1000_0058;
  localparam logic [63:0] MMIO_MTIMECMP = 64'h0000_0000_1000_0060;
  localparam logic [1:0]  ST_OK = 2'd0, ST_REFUSED = 2'd1, ST_LIMIT = 2'd2;

  // ---- job sequencing ------------------------------------------------------
  // C_HALTED: the core is frozen, not reset, so the host can read its
  // registers back through the debug port; a new job resets it first.
  typedef enum logic [1:0] { C_IDLE, C_START, C_RUN, C_HALTED } st_e;
  st_e st;
  logic        loaded;
  logic [31:0] entry, limit, count;
  logic [TAGW-1:0] tag_q;
  wire  HALTED;
  wire [63:0] csr_tohost;

  assign eng_ready = (st == C_IDLE) || (st == C_HALTED);
  wire accept    = eng_valid && eng_ready;
  wire malformed = !loaded || (entry[1:0] != 2'd0) || (entry >= MEM_BYTES);
  wire core_reset = (st == C_IDLE) || (st == C_START);   // frozen, not reset, once halted
  wire host_owns  = eng_ready && !accept;

  // ---- memory ------------------------------------------------------------------
  wire [63:0] icache_addr, dcache_addr, dcache_din;
  wire [7:0]  dcache_we;
  wire        dcache_re;
  wire [31:0] icache_dout;
  wire        icache_hit, dcache_hit;
  wire [63:0] mem_dout;
  wire        is_dev = (dcache_addr[63:8] == MMIO_BASE[63:8]);
  wire        host_we = ld_we && host_owns;
  wire        core_store_ok = (st == C_RUN) && !HALTED && !is_dev;

  // machine timer, reset with the core, as in Riscv64_top
  logic [63:0] mtime, mtimecmp;
  always_ff @(posedge clk) begin
    if (core_reset) begin
      mtime <= 64'd0; mtimecmp <= '1;
    end else begin
      mtime <= mtime + 64'd1;
      if (dcache_addr == MMIO_MTIMECMP)
        for (int b = 0; b < 8; b++) if (dcache_we[b]) mtimecmp[8*b +: 8] <= dcache_din[8*b +: 8];
    end
  end
  wire [63:0] dev_dout = (dcache_addr == MMIO_MTIME) ? mtime
                       : (dcache_addr == MMIO_MTIMECMP) ? mtimecmp : 64'd0;
  wire [63:0] dcache_dout = (dcache_addr == MMIO_MTIME || dcache_addr == MMIO_MTIMECMP) ? dev_dout : mem_dout;

  generate
    if (!CACHED) begin : g_flat
      logic [7:0] mem [MEM_BYTES];
      wire [15:0] ia = icache_addr[15:0];
      wire [15:0] da = {dcache_addr[15:3], 3'b000};
      assign icache_dout = {mem[ia + 16'd3], mem[ia + 16'd2], mem[ia + 16'd1], mem[ia]};
      assign icache_hit  = 1'b1;
      assign dcache_hit  = 1'b1;
      assign mem_dout = is_dev ? 64'd0 :
          {mem[da + 16'd7], mem[da + 16'd6], mem[da + 16'd5], mem[da + 16'd4],
           mem[da + 16'd3], mem[da + 16'd2], mem[da + 16'd1], mem[da]};
      always_ff @(posedge clk) begin
        if (host_we)
          for (int b = 0; b < 4; b++) mem[{ld_addr, 2'b00} + 16'(b)] <= ld_data[8*b +: 8];
        else if (core_store_ok)
          for (int b = 0; b < 8; b++) if (dcache_we[b]) mem[da + 16'(b)] <= dcache_din[8*b +: 8];
        rd_data <= {mem[{rd_addr, 2'b11}], mem[{rd_addr, 2'b10}], mem[{rd_addr, 2'b01}], mem[{rd_addr, 2'b00}]};
      end
    end else begin : g_cached
      // Sixfold's caches and its block memory, as in its Sixfold_System.sv.
      // The host shares the memory's one write port and its data refill
      // read port, and only while the core is not running.
      wire [63:0] irefill_addr, drefill_addr;
      wire [255:0] irefill_line, drefill_line;
      wire [63:0] cache_data;
      InstructionCache #(.MISS_LATENCY(MISS_LATENCY)) u_icache (
        .clk(clk), .reset(core_reset), .FREEZE(HALTED),
        .FETCH_ADDRESS(icache_addr), .INSTRUCTION(icache_dout), .HIT(icache_hit),
        .REFILL_ADDRESS(irefill_addr), .REFILL_LINE(irefill_line));
      DataCache #(.MISS_LATENCY(MISS_LATENCY)) u_dcache (
        .clk(clk), .reset(core_reset), .FREEZE(HALTED),
        .LOAD_REQUEST(dcache_re), .ADDRESS(dcache_addr), .WRITE_MASK(dcache_we), .WRITE_DATA(dcache_din),
        .READ_DATA(cache_data), .HIT(dcache_hit),
        .REFILL_ADDRESS(drefill_addr), .REFILL_LINE(drefill_line));
      assign mem_dout = is_dev ? 64'd0 : cache_data;
      // host words are 32 bits: put one in its doubleword lane
      wire [15:0] host_byte = {ld_addr, 2'b00};
      wire [15:0] w_addr = host_we ? {host_byte[15:3], 3'b000} : dcache_addr[15:0];
      wire [7:0]  w_mask = host_we ? (host_byte[2] ? 8'hF0 : 8'h0F) : (core_store_ok ? dcache_we : 8'h00);
      wire [63:0] w_data = host_we ? {ld_data, ld_data} : dcache_din;
      wire [15:0] rd_byte = {rd_addr, 2'b00};
      wire [15:0] d_refill = (st == C_RUN) ? drefill_addr[15:0] : rd_byte;
      MainMemory #(.LINES(MEM_BYTES / 32)) u_mem (
        .clk(clk), .WRITE_ADDRESS(w_addr), .WRITE_MASK(w_mask), .WRITE_DATA(w_data),
        .INSTRUCTION_REFILL_ADDRESS(irefill_addr[15:0]), .INSTRUCTION_REFILL_LINE(irefill_line),
        .DATA_REFILL_ADDRESS(d_refill), .DATA_REFILL_LINE(drefill_line));
      // the line arrives the cycle after its address; pick the host's word
      logic [2:0] rd_word_q;
      always_ff @(posedge clk) rd_word_q <= rd_byte[4:2];
      assign rd_data = drefill_line[32*rd_word_q +: 32];
    end
  endgenerate
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ld_refused <= 1'b0; else ld_refused <= ld_we && !host_owns;

  // ---- the core, unchanged -------------------------------------------------------
  /* verilator lint_off PINCONNECTEMPTY */
  Riscv64 #(
    .GSHARE_HISTORY_BITS(6), .BTB_ENABLE(1'b1), .RAS_ENABLE(1'b1), .PRECISE_LOAD_STALL(1'b1),
    .ITERATIVE_MULTIPLY_DIVIDE(1'b1), .TOURNAMENT_PREDICTOR(1'b1)
  ) u_core (
    .clk(clk), .reset(core_reset), .BRANCH_PREDICTION_ENABLE(1'b1),
    .RESET_VECTOR({32'd0, entry}),
    .TIMER_INTERRUPT_LINE(mtime >= mtimecmp), .EXTERNAL_INTERRUPT_LINE(1'b0),
    .dcache_addr(dcache_addr), .icache_addr(icache_addr), .dcache_we(dcache_we),
    .dcache_din(dcache_din), .dcache_dout(dcache_dout), .icache_dout(icache_dout),
    .icache_hit(icache_hit), .dcache_re(dcache_re), .dcache_hit(dcache_hit),
    .csr(csr_tohost), .HALTED(HALTED),
    .DEBUG_REGISTER_ADDRESS(dbg_reg), .DEBUG_REGISTER_DATA(dbg_data),
    .TRACE_VALID(), .TRACE_FETCH1_PC(), .TRACE_FETCH2_PC(), .TRACE_DECODE_PC(), .TRACE_EXECUTE_PC(),
    .TRACE_MEMORY_PC(), .TRACE_WRITEBACK_PC(), .TRACE_LOAD_STALL(), .TRACE_FLUSH(), .TRACE_REDIRECT(),
    .TRACE_MULTIPLY_DIVIDE_STALL(), .TRACE_INSTRUCTION_MISS(), .TRACE_DATA_MISS());
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- sequencing ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= C_IDLE; loaded <= 1'b0; entry <= 32'h2000; limit <= 32'd4_000_000; count <= '0;
      tag_q <= '0; eng_done <= 1'b0; eng_done_tag <= '0; job_status <= ST_OK; tohost <= '0;
      perf_cycles <= '0;
    end else begin
      eng_done <= 1'b0;
      if (host_we) loaded <= 1'b1;
      if (cfg_we && eng_ready) begin
        if (cfg_addr) limit <= cfg_data; else entry <= cfg_data;
      end
      unique case (st)
        C_IDLE, C_HALTED: if (accept) begin
          tag_q <= eng_tag;
          if (malformed) begin
            eng_done <= 1'b1; eng_done_tag <= eng_tag; job_status <= ST_REFUSED;
          end else st <= C_START;
        end
        C_START: begin count <= '0; st <= C_RUN; end   // one more cycle of reset: a clean start
        C_RUN: begin
          count <= count + 32'd1;
          if (HALTED) begin
            eng_done <= 1'b1; eng_done_tag <= tag_q; job_status <= ST_OK;
            tohost <= csr_tohost; perf_cycles <= count; st <= C_HALTED;
          end else if (count + 32'd1 >= limit) begin
            eng_done <= 1'b1; eng_done_tag <= tag_q; job_status <= ST_LIMIT;
            tohost <= '0; perf_cycles <= count; st <= C_IDLE;
          end
        end
        default: st <= C_IDLE;
      endcase
    end
  end

  wire _unused = &{eng_wd, dcache_re, 1'b0};
endmodule

`default_nettype wire
