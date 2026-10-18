#!/usr/bin/env python3
"""
mutate_mom.py -- put each SkyWater 130 audit fix in the dispatcher back, and
require the bench written for it to fail.

Each mutation is applied to a COPY of the repository (never this tree), the
named make target is run there, and the mutation counts as killed only if
that target fails. A baseline run of every target must pass first, or nothing
counts.

  python3 tools/mutate_mom.py          (make mom-mutate)
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

MUTATIONS = [
    ("MODEL-01 normalisation shift chosen from the highest nonzero byte", "mom/rtl/mom_cost_engine.sv",
     "    if      (t_pred_q[31:24] != 8'd0) tp_e = 5'd16;\n    else if (t_pred_q[23:16] != 8'd0) tp_e = 5'd8;",
     "    if      (t_pred_q[31:16] != 16'd0) tp_e = 5'd16;\n    else if (t_pred_q[15:8]  !=  8'd0) tp_e = 5'd8;",
     "cost-cal"),
    ("MODEL-02 calibration compares a 32-bit slice that wraps", "mom/rtl/mom_calibrate.sv",
     "  wire [COST_W+1:0]    t_cal      = t_cal_wide[39:KCAL_SHIFT];",
     "  wire [COST_W+1:0]    t_cal      = {2'b00, t_cal_wide[COST_W+KCAL_SHIFT-1 -: COST_W]};",
     "cost-cal"),
    ("MODEL-02 out-of-range update index not guarded", "mom/rtl/mom_calibrate.sv",
     "  wire upd_idx_ok = ({29'd0, upd_engine} < ENG_N) && ({28'd0, upd_opclass} < NOPC);",
     "  wire upd_idx_ok = 1'b1;",
     "cost-cal"),
    ("RTL-02 dispatch recorded on valid-and-not-HOLD, not on the crossbar handshake", "sys/rtl/hydra_sys_tile.sv",
     "    .disp_fire(disp_valid & disp_accept),",
     "    .disp_fire(disp_valid & regs_accept),",
     "systile"),
    ("RTL-04 multi-byte read not snapshotted", "mom/rtl/hydra_tt_regs.sv",
     "  wire         snap_use = (k != 5'd0) && (len <= 5'd6);",
     "  wire         snap_use = 1'b0;",
     "systile"),
    ("RTL-08 host completion accepted and discarded in the system tile", "sys/rtl/hydra_sys_tile.sv",
     "  hydra_tt_regs #(.NTAG(NTAG), .HOST_COMP(1'b0)) u_regs (",
     "  hydra_tt_regs #(.NTAG(NTAG), .HOST_COMP(1'b1)) u_regs (",
     "systile"),
    ("RTL-08 crossbar engine bound narrowed to the engine-ID width", "common/rtl/mom_xbar.sv",
     "  wire eng_in_range = ({1'b0, disp_engine} < (ENGW+1)'(NENG));",
     "  wire eng_in_range = (32'(disp_engine) < ENGW'(NENG));",
     "xbar-bound"),
    ("HOST-01 memory commands acknowledged on an image with no memory", "fpga/rtl/hydra_fpga_bridge.sv",
     "              (HAS_MEM && (rx_d == 8'h4D || rx_d == 8'h52))) st <= S_ARG;",
     "              (rx_d == 8'h4D || rx_d == 8'h52)) st <= S_ARG;",
     "harness"),
    # The second host path (Basys 3 image, 2026-10-17): each host must get its
    # own replies only, and a command must hear only the host that started it.
    ("JTAG-01 replies to a JTAG command also sent on the serial line", "fpga/rtl/hydra_fpga_bridge.sv",
     "    .clk(clk), .rst_n(rst_n), .start(tx_start && !src_j), .data(tx_d), .busy(tx_busy),",
     "    .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_d), .busy(tx_busy),",
     "jtag-harness"),
    ("JTAG-02 a byte from the other host accepted in the middle of a command", "fpga/rtl/hydra_fpga_bridge.sv",
     "  assign rx_v = in_idle ? (u_rx_v || j_v) : (src_j ? j_v : u_rx_v);",
     "  assign rx_v = u_rx_v || j_v;",
     "jtag-harness"),
    ("JTAG-03 the command's owner not recorded: JTAG replies go to the UART", "fpga/rtl/hydra_fpga_bridge.sv",
     "          src_j <= !u_rx_v;              // UART first if both arrive at once",
     "          src_j <= 1'b0;",
     "jtag-harness"),
    ("JTAG-04 reply queue read without advancing", "fpga/rtl/hydra_fpga_jtag_host.sv",
     "      if (pop)  rp <= rp + 1'b1;",
     "      if (1'b0) rp <= rp + 1'b1;",
     "jtag-harness"),
    # The GPU engine (Pixelstorm over a HYDRA bank, 2026-10-17).
    ("GPU-01 a line write answered before its words are written", "sys/rtl/hydra_engine_gpu.sv",
     "          if (w == 3'(LW - 1)) mst <= M_RESP;\n          w <= w + 3'd1;\n        end\n        M_AT_RD",
     "          mst <= M_RESP;\n          w <= w + 3'd1;\n        end\n        M_AT_RD",
     "gpu"),
    ("GPU-02 atomic add answers with the new value, not the old", "sys/rtl/hydra_engine_gpu.sv",
     "          if (op_q == 2'd2) m_resp_rdata <= {{(LW-1)*32{1'b0}}, ok_q ? old_q : 32'd0};",
     "          if (op_q == 2'd2) m_resp_rdata <= {{(LW-1)*32{1'b0}}, ok_q ? old_q + wdata_q[31:0] : 32'd0};",
     "gpu"),
    ("GPU-03 a line past the end of the bank wraps instead of being refused", "sys/rtl/hydra_engine_gpu.sv",
     "  wire line_ok = (m_req_addr < 32'(DEPTH)) && (m_req_addr + 32'(LW) <= 32'(DEPTH));",
     "  wire line_ok = 1'b1;",
     "gpu"),
    ("GPU-04 a block larger than one SM is launched", "sys/rtl/hydra_engine_gpu.sv",
     "                   (wd_block > 16'(WARPS * LANES)) || !prog_loaded;",
     "                   !prog_loaded;",
     "gpu"),
    ("GPU-05 line read words land one slot late", "sys/rtl/hydra_engine_gpu.sv",
     "          if (w != 3'd0 && ok_q) m_resp_rdata[(w - 3'd1) * 32 +: 32] <= b_rdata;",
     "          if (w != 3'd0 && ok_q && w != 3'd3) m_resp_rdata[w * 32 +: 32] <= b_rdata;",
     "gpu"),
    ("GPU-06 a host bank write accepted during a job", "sys/rtl/hydra_engine_gpu.sv",
     "  wire host_owns = (est == E_IDLE) && !accept;",
     "  wire host_owns = 1'b1;",
     "gpu"),
    ("GPU-07 a launch accepted with no program loaded", "sys/rtl/hydra_engine_gpu.sv",
     "      if (prog_we && eng_ready) prog_loaded <= 1'b1;",
     "      prog_loaded <= 1'b1;",
     "gpu"),
]


def copy_repo(dst):
    shutil.copytree(ROOT, dst, ignore=shutil.ignore_patterns(
        ".git", "build", "sim_build", "__pycache__", "*.vcd", "vendor_refs", "*_prove", "*_cover"))


def passes(tree, target):
    p = subprocess.run(["make", target], cwd=tree, capture_output=True, text=True, timeout=1800)
    return p.returncode == 0


def main():
    targets = sorted({m[4] for m in MUTATIONS})
    for label, f, old, _, _ in MUTATIONS:
        n = (ROOT / f).read_text().count(old)
        if n != 1:
            print(f"STALE ANCHOR '{label}': {f} matches {n} times")
            sys.exit(1)
    with tempfile.TemporaryDirectory() as td:
        base = pathlib.Path(td) / "base"
        copy_repo(base)
        for t in targets:
            if not passes(base, t):
                print(f"=== BASELINE NOT GREEN: make {t} fails unmutated -- NOTHING COUNTS ===")
                sys.exit(1)
        print(f"baseline green: {', '.join(targets)}\n")
        survived = 0
        for label, f, old, new, target in MUTATIONS:
            tree = pathlib.Path(td) / "mut"
            shutil.rmtree(tree, ignore_errors=True)
            shutil.copytree(base, tree)
            src = (tree / f).read_text()
            (tree / f).write_text(src.replace(old, new))
            if passes(tree, target):
                survived += 1
                print(f"  SURVIVED  {label}  (make {target} still passes)")
            else:
                print(f"  KILLED    {label}  by make {target}")
        print()
        if survived:
            print(f"=== {survived} MUTATION(S) SURVIVED ===")
            sys.exit(1)
        print(f"=== ALL {len(MUTATIONS)} DISPATCHER, BRIDGE AND GPU MUTATIONS KILLED ===")


if __name__ == "__main__":
    main()
