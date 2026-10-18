/*
 * hydra_abi_v2.sv -- descriptor ABI version 2: who may run a job, decided
 *                    before anything is costed
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * Chip only. The Tiny Tapeout tile speaks version 1 and is not affected.
 * Specification: docs/architecture/heterogeneous-system.md.
 *
 * ===========================================================================
 * THE HEADER (64 bits, in front of the unchanged 128-bit version-1 body)
 * ===========================================================================
 *   [63:60] abi_version    must be 2
 *   [59:58] security_mode  0 PUBLIC_DEBUG; 1 FHE, 2 SE, 3 reserved: refused
 *   [57:55] engine_policy  0 AUTO, 1 CPU, 2 GPU, 3 TPU, 4 SIMD, 5 NTT;
 *                          6 and 7 refused
 *   [54:47] context_id     the context this job belongs to
 *   [46:31] context_epoch  must equal the context's current epoch
 *   [30:23] key_handle     a key-vault slot; must be 0 in PUBLIC_DEBUG,
 *                          which uses no keys
 *   [22:15] profile_id     FHE or SE parameter set; must be 0 in PUBLIC_DEBUG
 *   [14:0]  reserved       must be 0, so a later version can use them
 *
 * ===========================================================================
 * ELIGIBILITY BEFORE COST, AND NO SILENT FALLBACK
 * ===========================================================================
 * A header that fails a check is refused here with a status code and the
 * body's tag, and never reaches the scheduler. A header that passes becomes
 * an eligibility mask over the engine slots:
 *     present AND healthy AND (policy == AUTO OR slot == policy's engine)
 * If that mask is empty (a forced engine that is absent or unhealthy) the
 * job is refused with NO_ENGINE. Otherwise the body goes to the scheduler
 * with the mask, and the scheduler masks engines out BEFORE comparing
 * costs; if none of the remaining engines can do the operation and data
 * type, the scheduler's own unsupported error is the job's answer. A job
 * is never moved to an engine outside its mask.
 *
 * Security modes FHE and SE are specifications only (docs/security/), so
 * this block refuses them, as tools/hydra_host.py check_job does on the
 * host. That stays true until each has positive and negative tests and a
 * board result.
 *
 * ===========================================================================
 * ONE JOB AT A TIME
 * ===========================================================================
 * The scheduler applies the mask at its select stage, several cycles after
 * the descriptor enters. So the mask must not change while a descriptor is
 * inside: this block forwards one descriptor, then waits for it to be
 * dispatched or refused (sched_done) before taking the next.
 *
 * ===========================================================================
 * CONTEXTS
 * ===========================================================================
 * NCTX contexts, each with an owned bit and a 16-bit epoch, written by the
 * host (ctx_we). Bumping a context's epoch revokes every job that still
 * carries the old one; clearing owned revokes the context.
 */
`default_nettype none

module hydra_abi_v2
  import mom_pkg::*;
#(
  parameter int unsigned NENG = ENG_N_CHIP,
  parameter int unsigned NCTX = 16,
  parameter logic [7:0]  PRESENT = 8'b0011_1111    // slots that exist on this chip
) (
  input  wire                clk,
  input  wire                rst_n,

  // ---- version-2 descriptor in ---------------------------------------------
  input  wire                in_valid,
  output logic               in_ready,
  input  wire  [63:0]        in_hdr,
  input  wire  [WD_W-1:0]    in_body,

  // ---- to the scheduler ------------------------------------------------------
  output logic               out_valid,
  input  wire                out_ready,
  output logic [WD_W-1:0]    out_body,
  output logic [NENG-1:0]    out_elig,
  input  wire                sched_done,      // the forwarded job was dispatched or refused

  // ---- refusal ---------------------------------------------------------------
  output logic               err_valid,       // one clock
  output logic [3:0]         err_code,
  output logic [7:0]         err_tag,

  // ---- host controls ---------------------------------------------------------
  input  wire                ctx_we,
  input  wire  [7:0]         ctx_id,
  input  wire                ctx_owned,
  input  wire  [15:0]        ctx_epoch,
  input  wire  [NENG-1:0]    healthy
);
  // status codes (0 is "accepted"; the scheduler's own refusal is separate)
  localparam logic [3:0] E_OK = 4'd0, E_VERSION = 4'd1, E_RESERVED = 4'd2, E_MODE = 4'd3,
                         E_POLICY = 4'd4, E_CONTEXT = 4'd5, E_KEY = 4'd6, E_NO_ENGINE = 4'd7;

  // ---- header fields ----------------------------------------------------------
  wire [3:0]  h_ver    = in_hdr[63:60];
  wire [1:0]  h_mode   = in_hdr[59:58];
  wire [2:0]  h_pol    = in_hdr[57:55];
  wire [7:0]  h_ctx    = in_hdr[54:47];
  wire [15:0] h_epoch  = in_hdr[46:31];
  wire [7:0]  h_key    = in_hdr[30:23];
  wire [7:0]  h_prof   = in_hdr[22:15];
  wire [14:0] h_rsvd   = in_hdr[14:0];

  // ---- context table ----------------------------------------------------------
  logic [NCTX-1:0] owned;
  logic [15:0]     epoch [NCTX];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      owned <= '0;
      for (int i = 0; i < NCTX; i++) epoch[i] <= '0;
    end else if (ctx_we && ({24'd0, ctx_id} < NCTX)) begin
      owned[ctx_id[$clog2(NCTX)-1:0]] <= ctx_owned;
      epoch[ctx_id[$clog2(NCTX)-1:0]] <= ctx_epoch;
    end
  end
  wire ctx_in_range = ({24'd0, h_ctx} < NCTX);
  wire ctx_ok = ctx_in_range && owned[h_ctx[$clog2(NCTX)-1:0]] &&
                (epoch[h_ctx[$clog2(NCTX)-1:0]] == h_epoch);

  // ---- policy to mask ---------------------------------------------------------
  // policy number -> engine slot (mom_pkg engine_e)
  function automatic logic [NENG-1:0] policy_mask(input logic [2:0] p);
    logic [NENG-1:0] m;
    m = '0;
    unique case (p)
      3'd0: m = '1;                                         // AUTO
      3'd1: m[ENG_CPU]  = 1'b1;
      3'd2: if (NENG > int'(ENG_GPU)) m[ENG_GPU] = 1'b1;    // no GPU slot: empty
      3'd3: m[ENG_TPU]  = 1'b1;
      3'd4: m[ENG_SIMD] = 1'b1;
      3'd5: m[ENG_NTT]  = 1'b1;
      default: m = '0;
    endcase
    return m;
  endfunction
  wire [NENG-1:0] elig = policy_mask(h_pol) & PRESENT[NENG-1:0] & healthy;

  // first failing check wins, in the order of the table above
  logic [3:0] verdict;
  always_comb begin
    if      (h_ver != 4'd2)                verdict = E_VERSION;
    else if (h_rsvd != 15'd0)              verdict = E_RESERVED;
    else if (h_mode != 2'd0)               verdict = E_MODE;
    else if (h_pol > 3'd5)                 verdict = E_POLICY;
    else if (!ctx_ok)                      verdict = E_CONTEXT;
    else if (h_key != 8'd0 || h_prof != 8'd0) verdict = E_KEY;
    else if (elig == '0)                   verdict = E_NO_ENGINE;
    else                                   verdict = E_OK;
  end

  // ---- one job at a time ------------------------------------------------------
  typedef enum logic [1:0] { S_IDLE, S_SEND, S_WAIT } st_e;
  st_e st;
  assign in_ready = (st == S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; out_valid <= 1'b0; out_body <= '0; out_elig <= '0;
      err_valid <= 1'b0; err_code <= E_OK; err_tag <= '0;
    end else begin
      err_valid <= 1'b0;
      unique case (st)
        S_IDLE: if (in_valid) begin
          if (verdict != E_OK) begin
            err_valid <= 1'b1; err_code <= verdict; err_tag <= in_body[42:35];   // work_desc_t.tag
          end else begin
            out_body <= in_body; out_elig <= elig; out_valid <= 1'b1; st <= S_SEND;
          end
        end
        S_SEND: if (out_ready) begin out_valid <= 1'b0; st <= S_WAIT; end
        S_WAIT: if (sched_done) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end

`ifdef FORMAL
  logic past_ok = 1'b0;
  always_ff @(posedge clk) past_ok <= 1'b1;
  // start in reset: the registers have no defined value before it
  always_comb if (!past_ok) assume (!rst_n);
  always_ff @(posedge clk) if (past_ok && rst_n && $past(rst_n)) begin
    // nothing reaches the scheduler without a passing header ...
    if (out_valid && !$past(out_valid)) assert ($past(verdict) == E_OK && $past(in_valid));
    // ... and the mask it carries is never empty and never names an absent slot
    if (out_valid) assert (out_elig != '0 && (out_elig & ~PRESENT[NENG-1:0]) == '0);
    // the mask cannot change while a job is inside the scheduler
    if (st != S_IDLE && $past(st) != S_IDLE) assert ($stable(out_elig));
    // FHE and SE are never forwarded
    if (out_valid && !$past(out_valid)) assert ($past(h_mode) == 2'd0);
  end
`endif

  wire _unused = &{h_key, h_prof, 1'b0};
endmodule

`default_nettype wire
