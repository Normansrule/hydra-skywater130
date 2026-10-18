// =============================================================================
// tb_abi_v2.sv -- the version-2 front end against an independent model
// =============================================================================
// Vectors from sys/tb/abi_v2_model.py (written from the specification, not
// from the RTL): context-table writes and jobs, each job with the status the
// model expects and, when accepted, the eligibility mask. For every job:
//   * a refusal: exactly one err_valid with the expected code and the body's
//     tag, and nothing sent to the scheduler
//   * an acceptance: the body goes out unchanged with the expected mask, no
//     error, and the block takes nothing new until the job is reported done
// The scheduler side stalls out_ready and delays sched_done at random, so the
// one-job-at-a-time rule is exercised, not assumed.
//   +vec=<file>
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_abi_v2;
  import mom_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic         in_valid = 0;
  wire          in_ready;
  logic [63:0]  in_hdr = '0;
  logic [127:0] in_body = '0;
  wire          out_valid;
  logic         out_ready = 0;
  wire [127:0]  out_body;
  wire [5:0]    out_elig;
  logic         sched_done = 0;
  wire          err_valid;
  wire [3:0]    err_code;
  wire [7:0]    err_tag;
  logic         ctx_we = 0, ctx_owned = 0;
  logic [7:0]   ctx_id = 0;
  logic [15:0]  ctx_epoch = 0;
  logic [5:0]   healthy = '1;

  hydra_abi_v2 #(.NENG(6), .NCTX(16)) dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_ready(in_ready), .in_hdr(in_hdr), .in_body(in_body),
    .out_valid(out_valid), .out_ready(out_ready), .out_body(out_body), .out_elig(out_elig),
    .sched_done(sched_done),
    .err_valid(err_valid), .err_code(err_code), .err_tag(err_tag),
    .ctx_we(ctx_we), .ctx_id(ctx_id), .ctx_owned(ctx_owned), .ctx_epoch(ctx_epoch),
    .healthy(healthy));

  int errors = 0, jobs = 0, accepted = 0, refused = 0, seed = 11;
  initial begin #500_000_000; $display("FAIL tb_abi_v2: watchdog"); $fatal(1); end

  // nothing may be taken while a job is job_inside
  bit job_inside = 0;
  always @(posedge clk) if (rst_n && job_inside && in_valid && in_ready) begin
    errors++; $display("FAIL: a new descriptor was accepted while a job was job_inside the scheduler");
  end

  string vec;
  integer fd, r;
  string kind;
  reg [63:0] h; reg [7:0] tag, hl, mask; reg [3:0] code; reg [31:0] a, b, c;
  initial begin
    if (!$value$plusargs("vec=%s", vec)) begin $display("FAIL: +vec= not given"); $fatal(1); end
    fd = $fopen(vec, "r");
    repeat (3) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%s", kind);
      if (r != 1) break;
      if (kind == "W") begin
        r = $fscanf(fd, "%h %h %h", a, b, c);
        @(negedge clk); ctx_we = 1; ctx_id = a[7:0]; ctx_owned = b[0]; ctx_epoch = c[15:0];
        @(negedge clk); ctx_we = 0;
      end else begin
        int t, errs_seen;
        logic [127:0] body;
        r = $fscanf(fd, "%h %h %h %h %h", h, tag, hl, code, mask);
        jobs++;
        body = {$urandom(seed), $urandom, $urandom, $urandom};
        body[42:35] = tag;
        @(negedge clk);
        healthy = hl[5:0];
        while (!in_ready) @(negedge clk);
        in_valid = 1; in_hdr = h; in_body = body;
        @(negedge clk); in_valid = 0;
        // watch the outcome for a while
        errs_seen = 0;
        for (t = 0; t < 4 && !out_valid; t++) begin
          if (err_valid) begin
            errs_seen++;
            if (err_code !== code || err_tag !== tag) begin
              errors++; if (errors < 10) $display("FAIL job %0d: refused with %0d tag %02x, model %0d tag %02x", jobs, err_code, err_tag, code, tag);
            end
          end
          @(negedge clk);
        end
        if (code != 0) begin
          refused++;
          if (errs_seen != 1) begin errors++; if (errors < 10) $display("FAIL job %0d: %0d error pulses for a refusal (code %0d)", jobs, errs_seen, code); end
          if (out_valid) begin errors++; if (errors < 10) $display("FAIL job %0d: a refused header reached the scheduler", jobs); end
        end else begin
          accepted++;
          if (errs_seen) begin errors++; if (errors < 10) $display("FAIL job %0d: an accepted header also raised an error", jobs); end
          if (!out_valid) begin errors++; if (errors < 10) $display("FAIL job %0d: an accepted header did not reach the scheduler", jobs); end
          else begin
            if (out_body !== body || out_elig !== mask[5:0]) begin
              errors++; if (errors < 10) $display("FAIL job %0d: mask %b body %s, model mask %b", jobs, out_elig, out_body === body ? "ok" : "CHANGED", mask[5:0]);
            end
            job_inside = 1;
            repeat ($urandom(seed) % 4) @(negedge clk);   // scheduler busy
            out_ready = 1; @(negedge clk); out_ready = 0;
            // a descriptor offered now must wait
            in_valid = 1; in_hdr = 64'h2 << 60; in_body = '0;
            repeat (1 + $urandom(seed) % 5) begin
              @(negedge clk);
              if (out_valid) begin errors++; $display("FAIL job %0d: a second job left before the first was done", jobs); end
            end
            in_valid = 0;
            sched_done = 1; @(negedge clk); sched_done = 0; job_inside = 0;
            @(negedge clk);
          end
        end
      end
    end
    if (errors) begin $display("FAIL tb_abi_v2: %0d errors in %0d jobs", errors, jobs); $fatal(1); end
    $display("PASS tb_abi_v2: %0d jobs (%0d accepted, %0d refused) match the model; one job at a time held", jobs, accepted, refused);
    $finish;
  end
endmodule
`default_nettype wire
