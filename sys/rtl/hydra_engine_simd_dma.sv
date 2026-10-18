/*
 * hydra_engine_simd_dma.sv -- the vector unit, fed from real memory
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY THE BANKS ARE WIDER HERE
 * ===========================================================================
 * The array eats four INT8 lanes per cycle, which is one 32-bit word, so its
 * banks are 32 bits and the host's word writes land one-to-one. The vector
 * unit eats four 32-bit lanes per cycle -- 128 bits -- so a 32-bit bank
 * would need four reads per group and the streamer would need burst logic.
 *
 * Widening the bank instead keeps the streamer exactly as it is: one word
 * per group, one group per cycle. The cost moves to the LOADER, which
 * assembles four host writes into one bank entry using the low two bits of
 * the address. That is the right place for it: the host already sends four
 * words, and gathering them at the memory is free, while burst logic in the
 * streamer would sit in the path of every engine that does not need it.
 *
 *   host address a  ->  bank entry a[9:2], lane a[1:0]
 *
 * So a group at bank entry g is written by host addresses 4g .. 4g+3, lane
 * order low to high. dma_simd_model.py produces exactly that order.
 *
 * ===========================================================================
 * RESULT ADDRESSES, AND WHAT DONE MEANS (audit R3, 2026-10-11)
 * ===========================================================================
 * The C bank holds DEPTH*4 words, but the result pointer used to be the
 * operand banks' width (AW = 8 bits, 256 words) and base_c used 8 of its 10
 * descriptor bits: results aimed above word 255 wrapped to the bottom of the
 * bank. Now base_c is a word address using all ten bits, the pointer is as
 * wide as the bank, and a job whose operands or results would run past the
 * end of a bank is refused before it starts (job_status = 4, nothing read
 * or written, the tag completes, the engine is free again).
 *
 * The core's done is held until the streamer has written every result, so a
 * host that reads the results the cycle after completion reads final values.
 * ===========================================================================
 * RESULT COUNT
 * ===========================================================================
 * An elementwise job writes one result per lane per group (4k); a reduction
 * writes one. The streamer takes that as an input rather than a parameter,
 * which is why one streamer serves both engines.
 */
`default_nettype none

module hydra_engine_simd_dma
  import simd_pkg::*;
#(
  parameter int unsigned N     = NLANE,
  parameter int unsigned WD_W  = 128,
  parameter int unsigned TAGW  = 4,
  parameter int unsigned AW    = 8,        // bank entries, not host words
  parameter int unsigned DEPTH = 256
) (
  input  wire              clk,
  input  wire              rst_n,

  input  wire              eng_valid,
  output logic             eng_ready,
  input  wire [WD_W-1:0]   eng_wd,
  input  wire [TAGW-1:0]   eng_tag,
  output logic             eng_done,
  output logic [TAGW-1:0]  eng_done_tag,

  // host load port: 32-bit words, bank 0 = A, 1 = B, 2 = C
  input  wire              ld_we,
  input  wire [1:0]        ld_bank,
  input  wire [AW+1:0]     ld_addr,        // two extra bits select the lane
  input  wire [31:0]       ld_data,
  output logic             ld_refused,      // pulses: a load the engine owned the banks for

  input  wire [AW+1:0]     c_raddr,
  output logic [31:0]      c_rdata,

  output logic [15:0]      jobs_done,
  output logic [2:0]       job_status       // the core's four, or 4 = past a bank's end
);
  localparam int unsigned GW  = N * EW;    // 128 bits: one group
  localparam int unsigned CAW = AW + 2;    // the C bank, in host words
  initial if (CAW > 10) $error("hydra_engine_simd_dma: base_c needs %0d bits; the field has 10", CAW);

  // ---- descriptor ---------------------------------------------------------
  wire [3:0]      wd_opclass = eng_wd[127:124];
  wire [CNTW-1:0] wd_m       = eng_wd[116:101];
  wire [AW-1:0]   base_a     = eng_wd[3  +: AW];
  wire [AW-1:0]   base_b     = eng_wd[13 +: AW];
  wire [CAW-1:0]  base_c     = eng_wd[23 +: CAW];   // a WORD address in C
  wire            is_reduce  = (wd_opclass == 4'd2);
  wire [CNTW-1:0] groups     = wd_m >> $clog2(N);
  wire [CNTW-1:0] n_results  = is_reduce ? CNTW'(1) : (groups * CNTW'(N));

  // The engine and the streamer must BOTH be free before a job is taken.
  // The engine's ready alone is not enough: the streamer can still be
  // draining the previous job's results for a cycle or two after the
  // engine reports idle.
  // The core's own acceptance test (simd_top / simd_ctrl), mirrored so the
  // streamer only starts for a job the core will run.
  wire core_will_run = ((wd_opclass == 4'd0) || (wd_opclass == 4'd1) || (wd_opclass == 4'd2)) &&
                       (eng_wd[123:121] == 3'd2) &&
                       (wd_m[$clog2(N)-1:0] == '0) && (wd_m != '0);
  wire in_range = ({1'b0, CNTW'(base_a)} + {1'b0, groups} <= (CNTW+1)'(DEPTH)) &&
                  ({1'b0, CNTW'(base_b)} + {1'b0, groups} <= (CNTW+1)'(DEPTH)) &&
                  ({1'b0, CNTW'(base_c)} + {1'b0, n_results} <= (CNTW+1)'(DEPTH * 4));

  wire dma_busy;
  wire core_ready;
  logic done_pend_q, rej_pend_q;
  logic [TAGW-1:0] pend_tag_q;
  assign eng_ready = core_ready && !dma_busy && !done_pend_q && !rej_pend_q;
  wire accept  = eng_valid && eng_ready;
  wire refuse  = accept && core_will_run && !in_range;
  wire to_core = accept && !refuse;
  wire run_job = to_core && core_will_run;

  // ---- loader: four host words become one bank entry ---------------------
  // Bank ownership (audit R8, 2026-10-11): from acceptance until the
  // completion is reported the engine owns every bank; a host write in that
  // window is refused and reported instead of taking the port.
  wire host_owns = eng_ready && !accept;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ld_refused <= 1'b0;
    else        ld_refused <= ld_we && !host_owns;

  wire [AW-1:0] ld_entry = ld_addr[AW+1:2];
  wire [1:0]    ld_lane  = ld_addr[1:0];

  wire [AW-1:0]  dma_a_addr, dma_b_addr;
  wire [CAW-1:0] dma_c_addr;
  wire [GW-1:0] a_rdata, b_rdata;
  wire [31:0]   c_wdata;
  wire          c_we;

  // Lane-sliced write enables: the bank is 128 bits wide but only the
  // addressed 32-bit lane is written, so the other three keep their values
  // and a group can be filled by four separate host commands.
  genvar l;
  generate
    for (l = 0; l < N; l++) begin : g_lane_bank
      wire a_we = ld_we && host_owns && (ld_bank == 2'd0) && (ld_lane == l[1:0]);
      wire b_we = ld_we && host_owns && (ld_bank == 2'd1) && (ld_lane == l[1:0]);

      hydra_spram #(.DW(EW), .DEPTH(DEPTH), .AW(AW)) u_a (
        .clk(clk), .we(a_we),
        .addr(a_we ? ld_entry : dma_a_addr),
        .wdata(ld_data), .rdata(a_rdata[l*EW +: EW]));

      hydra_spram #(.DW(EW), .DEPTH(DEPTH), .AW(AW)) u_b (
        .clk(clk), .we(b_we),
        .addr(b_we ? ld_entry : dma_b_addr),
        .wdata(ld_data), .rdata(b_rdata[l*EW +: EW]));
    end
  endgenerate

  // Results are 32 bits, so the C bank stays narrow and the host reads it
  // word by word exactly as it does for the array.
  wire        c_ld_we = ld_we && host_owns && (ld_bank == 2'd2);
  wire [AW+1:0] c_addr = c_ld_we ? ld_addr :
                         c_we    ? dma_c_addr : c_raddr;

  hydra_spram #(.DW(32), .DEPTH(DEPTH*4), .AW(AW+2)) u_c (
    .clk(clk), .we(c_we || c_ld_we), .addr(c_addr),
    .wdata(c_ld_we ? ld_data : c_wdata), .rdata(c_rdata));

  // ---- streamer -----------------------------------------------------------
  wire            op_valid, op_ready;
  wire [GW-1:0]   op_a, op_b;
  wire            res_valid, res_last;
  wire signed [EW-1:0] res_data;

  hydra_dma_gemm #(.AW(AW), .CAW(CAW), .DW(GW), .CNTW(CNTW)) u_dma (
    .clk(clk), .rst_n(rst_n),
    .start(run_job), .base_a(base_a), .base_b(base_b), .base_c(base_c),
    .k_slices(groups), .n_results(n_results), .busy(dma_busy),
    .a_addr(dma_a_addr), .a_rdata(a_rdata),
    .b_addr(dma_b_addr), .b_rdata(b_rdata),
    .w_addr(), .w_rdata({GW{1'b0}}), .op_w(),
    .c_addr(dma_c_addr), .c_we(c_we), .c_wdata(c_wdata),
    .op_valid(op_valid), .op_ready(op_ready), .op_a(op_a), .op_b(op_b),
    .res_valid(res_valid), .res_data(res_data));

  wire            core_done;
  wire [TAGW-1:0] core_done_tag;
  simd_status_e   core_status;
  simd_top #(.N(N), .WD_W(WD_W), .TAGW(TAGW)) u_simd (
    .clk(clk), .rst_n(rst_n),
    .eng_valid(to_core), .eng_ready(core_ready), .eng_wd(eng_wd),
    .eng_tag(eng_tag), .eng_done(core_done), .eng_done_tag(core_done_tag),
    .op_ready(op_ready), .op_valid(op_valid), .op_a(op_a), .op_b(op_b),
    .res_valid(res_valid), .res_data(res_data), .res_last(res_last),
    .status(core_status));

  // ---- completion: after the last result is in the C bank ---------------------
  wire commit_ok = done_pend_q && !dma_busy && !res_valid;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_pend_q <= 1'b0; rej_pend_q <= 1'b0; pend_tag_q <= '0;
      eng_done <= 1'b0; eng_done_tag <= '0; job_status <= 3'd0; jobs_done <= '0;
    end else begin
      eng_done <= 1'b0;
      if (core_done) begin
        done_pend_q <= 1'b1; pend_tag_q <= core_done_tag; job_status <= {1'b0, core_status};
      end
      if (refuse) begin
        rej_pend_q <= 1'b1; pend_tag_q <= eng_tag; job_status <= 3'd4;
      end
      if (commit_ok || rej_pend_q) begin
        eng_done <= 1'b1; eng_done_tag <= pend_tag_q;
        done_pend_q <= 1'b0; rej_pend_q <= 1'b0;
        jobs_done <= jobs_done + 16'd1;
      end
    end
  end

  wire _unused = &{res_last, 1'b0};
endmodule

`default_nettype wire
