#!/usr/bin/env python3
"""
mutate_dma.py -- break the memory path; every break must be caught.

Runs all three engine benches (the array never stalls, the vector unit stalls
four cycles per group; the streamer's two worst bugs were only visible to
the one that stalls; the butterfly engine writes eight words per group)
plus the streamer's own proof.

The baseline is checked FIRST. A mutation score measured against a red
baseline is meaningless -- every mutation looks "killed" because the
unmutated design already fails -- and that happened once in this project.
"""
import pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent      # mem/
REPO = ROOT.parent

SIM = [
    ("memory latency wait skipped", "rtl/hydra_dma_gemm.sv",
     "          st_q         <= (k_slices == '0) ? S_IDLE : S_PRIME;",
     "          st_q         <= (k_slices == '0) ? S_IDLE : S_STREAM;"),
    ("operand straight off the bank, no holding register",
     "rtl/hydra_dma_gemm.sv",
     "  assign op_a     = hold_a_q;\n  assign op_b     = hold_b_q;",
     "  assign op_a     = a_rdata;\n  assign op_b     = b_rdata;"),
    ("address advances without a capture (no re-present on stall)",
     "rtl/hydra_dma_agen.sv",
     "  assign addr_a   = ba_q + AW'(rd_q) + AW'(peek);\n  assign addr_b   = bb_q + AW'(rd_q) + AW'(peek);",
     "  assign addr_a   = ba_q + AW'(rd_q) + 1'b1;\n  assign addr_b   = bb_q + AW'(rd_q) + 1'b1;"),
    ("capture while the held word is still waiting", "rtl/hydra_dma_gemm.sv",
     "  wire capture = bank_ok && (!hold_valid_q || xfer);",
     "  wire capture = bank_ok;"),
    ("read pointer never advances", "rtl/hydra_dma_agen.sv",
     "      if (step_rd) rd_q <= rd_q + CNTW'(1);", "      if (1'b0) rd_q <= rd_q + CNTW'(1);"),
    ("write pointer never advances", "rtl/hydra_dma_agen.sv",
     "      if (step_wr) wr_q <= wr_q + CNTW'(1);", "      if (1'b0) wr_q <= wr_q + CNTW'(1);"),
    ("A and B swapped", "rtl/hydra_dma_gemm.sv",
     "        hold_a_q     <= a_rdata;\n        hold_b_q     <= b_rdata;",
     "        hold_a_q     <= b_rdata;\n        hold_b_q     <= a_rdata;"),
    ("result base ignored", "rtl/hydra_dma_agen.sv",
     "  assign addr_c   = bc_q + CAW'(wr_q);", "  assign addr_c   = CAW'(wr_q);"),
    # The butterfly engine's adapter (audit R2/R3, 2026-10-11). Its bench runs
    # at q = 3329, the modulus the old 16-bit-slot format got wrong.
    ("TPU streamer started for a descriptor the core refuses (wedges the engine)",
     "../sys/rtl/hydra_engine_tpu_dma.sv",
     "  wire run_job = to_core && core_will_run;", "  wire run_job = to_core;"),
    ("TPU job past the end of a bank not refused", "../sys/rtl/hydra_engine_tpu_dma.sv",
     "  wire refuse  = accept && core_will_run && !in_range;", "  wire refuse  = 1'b0;"),
    ("vector-unit streamer started for a descriptor the core refuses",
     "../sys/rtl/hydra_engine_simd_dma.sv",
     "  wire run_job = to_core && core_will_run;", "  wire run_job = to_core;"),
    ("vector-unit result pointer only as wide as the operand banks",
     "../sys/rtl/hydra_engine_simd_dma.sv",
     "  hydra_dma_gemm #(.AW(AW), .CAW(CAW), .DW(GW), .CNTW(CNTW)) u_dma (",
     "  hydra_dma_gemm #(.AW(AW), .CAW(AW), .DW(GW), .CNTW(CNTW)) u_dma ("),
    ("NTT completion reported before the last result is written", "../sys/rtl/hydra_engine_ntt_dma.sv",
     "  wire commit_ok = done_pend_q && !dma_busy && !ser_busy && !res_valid;",
     "  wire commit_ok = done_pend_q;"),
    ("NTT residue >= q accepted at the load port", "../sys/rtl/hydra_engine_ntt_dma.sv",
     "  wire          res_ok   = (ld_data >> QW) == '0 && ld_data[QW-1:0] < QW'(Q);",
     "  wire          res_ok   = 1'b1;"),
    ("NTT job past the end of a bank not refused", "../sys/rtl/hydra_engine_ntt_dma.sv",
     "  wire in_range = fits(base_a, groups) && fits(base_b, groups) && fits(base_c, groups);",
     "  wire in_range = 1'b1;"),
    ("NTT y0 and y1 written in the wrong order", "../sys/rtl/hydra_engine_ntt_dma.sv",
     "  wire [31:0]   res_word = ser_idx[0] ? 32'(ser_y1[ser_lane*QW +: QW])\n                                      : 32'(ser_y0[ser_lane*QW +: QW]);",
     "  wire [31:0]   res_word = ser_idx[0] ? 32'(ser_y0[ser_lane*QW +: QW])\n                                      : 32'(ser_y1[ser_lane*QW +: QW]);"),
    ("NTT result base taken as a word, not a group", "../sys/rtl/hydra_engine_ntt_dma.sv",
     "    .base_c(CAW'({base_c, {RW{1'b0}}})),",
     "    .base_c(CAW'(base_c)),"),
    ("TPU host load accepted while the engine owns the banks", "../sys/rtl/hydra_engine_tpu_dma.sv",
     "  wire host_owns = eng_ready && !accept;", "  wire host_owns = 1'b1;"),
    ("vector-unit host load accepted while the engine owns the banks", "../sys/rtl/hydra_engine_simd_dma.sv",
     "  wire host_owns = eng_ready && !accept;", "  wire host_owns = 1'b1;"),
    ("NTT host load accepted while the engine owns the banks", "../sys/rtl/hydra_engine_ntt_dma.sv",
     "  wire          host_owns = eng_ready && !accept;", "  wire          host_owns = 1'b1;"),
    ("TPU ownership returned at acceptance, not completion", "../sys/rtl/hydra_engine_tpu_dma.sv",
     "  wire host_owns = eng_ready && !accept;", "  wire host_owns = !accept;"),
    ("writes enabled without a result", "rtl/hydra_dma_gemm.sv",
     "  assign c_we     = res_valid;", "  assign c_we     = 1'b1;"),
]

# "Offer an operand during the memory-latency wait" used to be here. It is
# now EQUIVALENT: the holding register is empty in that state by
# construction (and asserted so in the proof), so op_valid cannot rise there
# whatever the expression says. Removed rather than left to "survive", with
# the reason written down, because an equivalent mutant is not a test gap.
FORMAL = [
    ("result count ignored: free after the first result", "rtl/hydra_dma_gemm.sv",
     "  wire busy_hold = (res_seen_q < n_q);", "  wire busy_hold = 1'b0;"),
    ("result count read live from the shared bus, not latched", "rtl/hydra_dma_gemm.sv",
     "          n_q          <= n_results;", "          n_q          <= '0;"),
    ("zero-length job wraps the counter", "rtl/hydra_dma_gemm.sv",
     "          st_q         <= (k_slices == '0) ? S_IDLE : S_PRIME;",
     "          st_q         <= S_PRIME;"),
    ("start accepted while draining", "rtl/hydra_dma_gemm.sv",
     "  wire go      = start && (st_q == S_IDLE);", "  wire go      = start;"),
]

BENCHES = [
    ("tb_hydra_dma",
     "sv2v engines/tpu/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_tpu_dma.sv "
     "mem/tb/tb_hydra_dma.sv > build/sim/mdma.v && iverilog -g2012 -o build/sim/mdma "
     "build/sim/mdma.v 2>/dev/null && vvp -n build/sim/mdma"),
    ("tb_hydra_dma_simd",
     "sv2v engines/simd/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_simd_dma.sv "
     "mem/tb/tb_hydra_dma_simd.sv > build/sim/mdmas.v && iverilog -g2012 -o build/sim/mdmas "
     "build/sim/mdmas.v 2>/dev/null && vvp -n build/sim/mdmas"),
    ("tb_hydra_dma_ntt",
     "HYDRA_NTT_Q=3329 python3 mem/tb/dma_ntt_model.py > /dev/null && "
     "sv2v --define=HYDRA_NTT_Q=3329 engines/ntt/rtl/*.sv mem/rtl/*.sv "
     "sys/rtl/hydra_engine_ntt_dma.sv mem/tb/tb_hydra_dma_ntt.sv > build/sim/mdman.v && "
     "iverilog -g2012 -o build/sim/mdman build/sim/mdman.v 2>/dev/null && vvp -n build/sim/mdman; "
     "python3 mem/tb/dma_ntt_model.py > /dev/null"),
]


def run(cmd, cwd, timeout=300):
    try:
        return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True,
                              text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        class R: stdout = "TIMEOUT"
        return R()


def with_mutation(rel, old, new, body):
    src = ROOT / rel
    orig = src.read_text()
    if orig.count(old) != 1:
        return None, f"anchor not unique ({orig.count(old)}) in {rel}"
    src.write_text(orig.replace(old, new))
    try:
        return body(), None
    finally:
        src.write_text(orig)


def sim_passes():
    (REPO / "build" / "sim").mkdir(parents=True, exist_ok=True)
    return all(f"PASS {name}" in run(cmd, REPO).stdout for name, cmd in BENCHES)


def formal_passes():
    c = run("sv2v --define=FORMAL -E Assert rtl/hydra_dma_agen.sv "
            "rtl/hydra_dma_gemm.sv > formal/hydra_dma_sv2v.v && "
            "cd formal && sby -f hydra_dma_gemm.sby prove", ROOT)
    return "DONE (PASS" in c.stdout


def main():
    if not sim_passes() or not formal_passes():
        print("BASELINE IS RED: fix the design before reading any mutation score.")
        sys.exit(2)
    print("baseline green: both benches pass, proof passes\n")
    killed = survived = 0
    for group, passes, tag in ((FORMAL, formal_passes, "formal"),
                               (SIM, sim_passes, "simulation")):
        for name, rel, old, new in group:
            caught, err = with_mutation(rel, old, new, lambda: not passes())
            if err:
                print(f"SKIP  {name}: {err}"); continue
            print(("KILL  " if caught else "ALIVE ") + name + f"  [{tag}]")
            killed += caught; survived += not caught
    print(f"\n{killed} killed, {survived} survived")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
