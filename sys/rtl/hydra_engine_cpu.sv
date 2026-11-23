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
 * MEMORY. 64 KiB. CACHED = 1 (the system tile's default): Sixfold's 4 KiB
 * instruction and data caches over its line-wide block memory, the
 * arrangement of its FPGA system; this is the build that synthesizes.
 * CACHED = 0: one unified array read in the same cycle with both cache hits
 * tied to 1 (Riscv64_top with CACHES_ENABLE = 0), a simulation reference.
 *
 * DEVICES. The machine timer (MTIME, MTIMECMP) as in Riscv64_top, so
 * programs that use timer interrupts behave as in the model. Since v67 the
 * console and LEDs reach pins: a store to PUTCHAR (0x1000_0000) queues the
 * byte for a UART transmitter (8 data bits, no parity, 1 stop bit, UART_DIV
 * clocks per bit) on uart_tx; LEDS (0x1000_0008, 16 bits, byte-merged as in
 * the model) drives gpio_out; BUTTONS (0x1000_0010) reads gpio_in through a
 * two-flop synchroniser. The core never waits for the UART: a full queue
 * drops the byte and counts it, so the core's timing stays the model's.
 * Extra registers, which the model does not have (it reads 0 there):
 *   0x1000_0080 UART_DIV     RW  clocks per bit, 16 bits
 *   0x1000_0088 UART_STATUS  R   [0] busy, [1] queue full, [15:8] dropped
 * A program that must not lose bytes polls UART_STATUS[1]. Every other
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
  // with CACHED = 1: 0 Sixfold's MainMemory (FPGA block RAM), 1 SkyWater 130
  // SRAM macros (sys/rtl/hydra_cpu_sram.sv); SRAM_MODEL = 1 swaps the macros for
  // an equivalent model (FPGA, Verilator)
  parameter bit          SRAM = 1'b0,
  // with CACHED = 1: sets per way in each of Sixfold's caches. 64 is Sixfold's
  // default (4 KiB each); the chip uses 16 (1 KiB each), Sixfold's "compact" build
  parameter int unsigned CACHE_SETS = 64,
  parameter bit          SRAM_MODEL = 1'b0,
  // 0  memory read in the same cycle, no caches (Riscv64_top with
  //    CACHES_ENABLE = 0): the simulation arrangement
  // 1  Sixfold's own instruction and data caches over a line-wide block
  //    memory (its fpga/rtl/Main_Memory.sv, the arrangement its FPGA system
  //    uses): synthesizable, block RAM on an FPGA, SRAM macros on a chip
  parameter bit          CACHED = 1'b0,
  parameter int unsigned MISS_LATENCY = 10,
  // the console UART: clocks per bit after reset, and the queue depth (a
  // power of two)
  parameter int unsigned UART_DIV  = 16,
  parameter int unsigned UART_FIFO = 16
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
  // the dispatch port (v3.12): the running program hands work to the
  // scheduler through memory-mapped registers (see DISPATCH PORT below)
  output logic             disp_valid,     // a descriptor waits for the scheduler
  output logic [127:0]     disp_wd,
  output logic [63:0]      disp_hdr,
  input  wire              disp_taken,     // taken (accepted or refused) this cycle
  input  wire  [63:0]      disp_status,    // counters kept by the system tile

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

  output logic [31:0]      perf_cycles,    // cycles from the core leaving reset to HALTED

  // devices on pins (v67)
  output logic             uart_tx,        // idle high
  output wire              uart_idle,      // queue empty and nothing shifting
  output logic [15:0]      gpio_out,       // the LEDS register
  input  wire  [15:0]      gpio_in         // the BUTTONS register, synchronised here
);
  localparam logic [63:0] MMIO_BASE     = 64'h0000_0000_1000_0000;
  localparam logic [63:0] MMIO_PUTCHAR  = 64'h0000_0000_1000_0000;
  localparam logic [63:0] MMIO_LEDS     = 64'h0000_0000_1000_0008;
  localparam logic [63:0] MMIO_BUTTONS  = 64'h0000_0000_1000_0010;
  localparam logic [63:0] MMIO_UART_DIV = 64'h0000_0000_1000_0080;
  localparam logic [63:0] MMIO_UART_ST  = 64'h0000_0000_1000_0088;
  localparam logic [63:0] MMIO_MTIME    = 64'h0000_0000_1000_0058;
  localparam logic [63:0] MMIO_MTIMECMP = 64'h0000_0000_1000_0060;
  // DISPATCH PORT. 64-bit registers in Sixfold's device page:
  //   0x1000_0100 DESC_LO  W  descriptor [63:0]
  //   0x1000_0108 DESC_HI  W  descriptor [127:64]
  //   0x1000_0110 HDR      W  the ABI version 2 header
  //   0x1000_0118 SUBMIT   W  any store: offer the descriptor to the scheduler
  //   0x1000_0120 STATUS   R  [0] still waiting, [15:8] refused, [19:16] last
  //                          refusal code, [31:24] dispatched, [47:32] completed,
  //                          [63:48] tags still outstanding (the system tile's counts)
  // A store to SUBMIT while one is still waiting is ignored: STATUS[0] says
  // when the port is free again. The CPU itself is never eligible for work it
  // submits, so a program cannot wait on a job queued behind itself.
  localparam logic [63:0] MMIO_DESC_LO  = 64'h0000_0000_1000_0100;
  localparam logic [63:0] MMIO_DESC_HI  = 64'h0000_0000_1000_0108;
  localparam logic [63:0] MMIO_HDR      = 64'h0000_0000_1000_0110;
  localparam logic [63:0] MMIO_SUBMIT   = 64'h0000_0000_1000_0118;
  localparam logic [63:0] MMIO_STATUS   = 64'h0000_0000_1000_0120;
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
  wire        icache_invalidate; // fence.i in EXECUTE: the instruction cache empties at this edge
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

  // ---- the dispatch port ------------------------------------------------------
  wire disp_store = (st == C_RUN) && !HALTED && (dcache_we != 8'd0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      disp_valid <= 1'b0; disp_wd <= '0; disp_hdr <= '0;
    end else begin
      if (disp_taken) disp_valid <= 1'b0;
      if (disp_store) begin
        for (int b = 0; b < 8; b++) if (dcache_we[b]) begin
          if (dcache_addr == MMIO_DESC_LO) disp_wd[8*b +: 8]      <= dcache_din[8*b +: 8];
          if (dcache_addr == MMIO_DESC_HI) disp_wd[64 + 8*b +: 8] <= dcache_din[8*b +: 8];
          if (dcache_addr == MMIO_HDR)     disp_hdr[8*b +: 8]     <= dcache_din[8*b +: 8];
        end
        if (dcache_addr == MMIO_SUBMIT && !disp_valid) disp_valid <= 1'b1;
      end
    end
  end
  // ---- console UART, LEDs and buttons (v67) ----------------------------------
  // A store is in Execute for exactly one cycle (Sixfold's dcache_we is gated
  // by EXECUTE_VALID and FREEZE, and nothing holds a store in Execute), so
  // each PUTCHAR store queues exactly one byte.
  localparam int QW = $clog2(UART_FIFO);
  wire dev_store = disp_store;
  logic [7:0]    uq [UART_FIFO];
  logic [QW:0]   uq_wp, uq_rp;
  logic [15:0]   uart_div;
  logic [7:0]    uart_dropped;
  logic [9:0]    tx_shift;          // stop, 8 data bits LSB first, start
  logic [3:0]    tx_bits;           // bits still to send
  logic [15:0]   tx_count;
  logic [1:0][15:0] btn_sync;
  wire uq_empty = (uq_wp == uq_rp);
  wire uq_full  = (uq_wp[QW-1:0] == uq_rp[QW-1:0]) && (uq_wp[QW] != uq_rp[QW]);
  wire put_now  = dev_store && (dcache_addr == MMIO_PUTCHAR) && dcache_we[0];
  assign uart_idle = uq_empty && (tx_bits == 4'd0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      uq_wp <= '0; uq_rp <= '0; uart_div <= 16'(UART_DIV); uart_dropped <= '0;
      tx_shift <= '1; tx_bits <= '0; tx_count <= '0; uart_tx <= 1'b1;
      gpio_out <= '0; btn_sync <= '0;
    end else begin
      btn_sync <= {btn_sync[0], gpio_in};
      if (put_now) begin
        if (uq_full) uart_dropped <= uart_dropped + {7'd0, uart_dropped != 8'hFF};
        else begin uq[uq_wp[QW-1:0]] <= dcache_din[7:0]; uq_wp <= uq_wp + 1'b1; end
      end
      if (dev_store && dcache_addr == MMIO_UART_DIV) begin
        if (dcache_we[0]) uart_div[7:0]  <= dcache_din[7:0];
        if (dcache_we[1]) uart_div[15:8] <= dcache_din[15:8];
      end
      if (dev_store && dcache_addr == MMIO_LEDS) begin
        if (dcache_we[0]) gpio_out[7:0]  <= dcache_din[7:0];
        if (dcache_we[1]) gpio_out[15:8] <= dcache_din[15:8];
      end
      // the transmitter: load a frame when idle, shift one bit per uart_div clocks
      if (tx_bits == 4'd0) begin
        if (!uq_empty) begin
          tx_shift <= {1'b1, uq[uq_rp[QW-1:0]], 1'b0};
          uq_rp <= uq_rp + 1'b1; tx_bits <= 4'd10; tx_count <= '0;
        end
      end else if (tx_count + 16'd1 >= uart_div) begin
        tx_count <= '0; tx_shift <= {1'b1, tx_shift[9:1]}; tx_bits <= tx_bits - 4'd1;
      end else tx_count <= tx_count + 16'd1;
      uart_tx <= (tx_bits == 4'd0) ? 1'b1 : tx_shift[0];
    end
  end

  wire [63:0] dev_dout = (dcache_addr == MMIO_MTIME) ? mtime
                       : (dcache_addr == MMIO_BUTTONS) ? {48'd0, btn_sync[1]}
                       : (dcache_addr == MMIO_UART_DIV) ? {48'd0, uart_div}
                       : (dcache_addr == MMIO_UART_ST) ? {48'd0, uart_dropped, 6'd0, uq_full, !uart_idle}
                       : (dcache_addr == MMIO_MTIMECMP) ? mtimecmp
                       : (dcache_addr == MMIO_STATUS) ? {disp_status[63:1], disp_valid} : 64'd0;
  wire [63:0] dcache_dout = (dcache_addr == MMIO_MTIME || dcache_addr == MMIO_MTIMECMP ||
                             dcache_addr == MMIO_STATUS || dcache_addr == MMIO_BUTTONS ||
                             dcache_addr == MMIO_UART_DIV || dcache_addr == MMIO_UART_ST) ? dev_dout : mem_dout;

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
      InstructionCache #(.MISS_LATENCY(MISS_LATENCY), .SETS(CACHE_SETS)) u_icache (
        .clk(clk), .reset(core_reset || icache_invalidate), .FREEZE(HALTED),
        .FETCH_ADDRESS(icache_addr), .INSTRUCTION(icache_dout), .HIT(icache_hit),
        .REFILL_ADDRESS(irefill_addr), .REFILL_LINE(irefill_line));
      DataCache #(.MISS_LATENCY(MISS_LATENCY), .SETS(CACHE_SETS)) u_dcache (
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
      // programs live in the low 64 KiB; host words are 32-bit aligned
      wire _unused_hi = &{1'b0, irefill_addr[63:16], drefill_addr[63:16], host_byte[1:0]};
      if (SRAM) begin : g_sram
        hydra_cpu_sram #(.LINES(MEM_BYTES / 32), .MACROS(!SRAM_MODEL)) u_mem (
          .clk(clk), .WRITE_ADDRESS(w_addr), .WRITE_MASK(w_mask), .WRITE_DATA(w_data),
          .INSTRUCTION_REFILL_ADDRESS(irefill_addr[15:0]), .INSTRUCTION_REFILL_LINE(irefill_line),
          .DATA_REFILL_ADDRESS(d_refill), .DATA_REFILL_LINE(drefill_line), .check_en(st == C_RUN));
      end else begin : g_bram
        MainMemory #(.LINES(MEM_BYTES / 32)) u_mem (
          .clk(clk), .WRITE_ADDRESS(w_addr), .WRITE_MASK(w_mask), .WRITE_DATA(w_data),
          .INSTRUCTION_REFILL_ADDRESS(irefill_addr[15:0]), .INSTRUCTION_REFILL_LINE(irefill_line),
          .DATA_REFILL_ADDRESS(d_refill), .DATA_REFILL_LINE(drefill_line));
      end
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
    .ITERATIVE_MULTIPLY_DIVIDE(1'b1), .TOURNAMENT_PREDICTOR(1'b1), .ZIFENCEI(1'b1)
  ) u_core (
    .clk(clk), .reset(core_reset), .BRANCH_PREDICTION_ENABLE(1'b1),
    .RESET_VECTOR({32'd0, entry}),
    .TIMER_INTERRUPT_LINE(mtime >= mtimecmp), .EXTERNAL_INTERRUPT_LINE(1'b0),
    .dcache_addr(dcache_addr), .icache_addr(icache_addr), .dcache_we(dcache_we),
    .dcache_din(dcache_din), .dcache_dout(dcache_dout), .icache_dout(icache_dout),
    .icache_hit(icache_hit), .icache_invalidate(icache_invalidate), .dcache_re(dcache_re), .dcache_hit(dcache_hit),
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

  wire _unused = &{eng_wd, dcache_re, disp_status[0], 1'b0};   // STATUS[0] is the port's own waiting bit
endmodule

`default_nettype wire
