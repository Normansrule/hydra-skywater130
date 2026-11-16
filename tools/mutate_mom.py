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
     "  wire upd_idx_ok = ({29'd0, upd_engine} < NENG) && ({28'd0, upd_opclass} < NOPC);",
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
     "          if (w != 3'd0 && ok_q) m_resp_rdata[{LWB'(w - 3'd1), 5'd0} +: 32] <= b_rdata;",
     "          if (w != 3'd0 && ok_q && w != 3'd3) m_resp_rdata[{LWB'(w), 5'd0} +: 32] <= b_rdata;",
     "gpu"),
    ("GPU-06 a host bank write accepted during a job", "sys/rtl/hydra_engine_gpu.sv",
     "  wire host_owns = (est == E_IDLE) && !accept;",
     "  wire host_owns = 1'b1;",
     "gpu"),
    ("GPU-07 a launch accepted with no program loaded", "sys/rtl/hydra_engine_gpu.sv",
     "      if (prog_we && eng_ready) prog_loaded <= 1'b1;",
     "      prog_loaded <= 1'b1;",
     "gpu"),
    # Six slots on the chip (NENG = 6, 2026-10-18).
    ("SLOT-01 the select tree stops at five lanes and never sees the GPU", "mom/rtl/mom_select.sv",
     "  wire [PW-1:0] best = best_chain[NENG-5];",
     "  wire [PW-1:0] best = best_chain[0];",
     "systile-gpu"),
    ("SLOT-02 the GPU's parameter row is never loaded", "mom/rtl/mom_param_rom.sv",
     "      if (NENG > int'(ENG_GPU)) row[GPU_ROW] <= DEF_GPU;",
     "      if (NENG > int'(ENG_GPU)) row[GPU_ROW] <= '0;",
     "systile-gpu"),
    ("SLOT-03 engine 5's completion taken from the latency model, not the GPU", "sys/rtl/hydra_sys_tile.sv",
     "        assign eng_done[e]            = REAL_GPU ? gpu_done     : done_q;",
     "        assign eng_done[e]            = done_q;",
     "systile-gpu"),
    # Descriptor ABI version 2 (2026-10-18).
    ("ABI-01 security mode FHE or SE accepted", "sys/rtl/hydra_abi_v2.sv",
     "    else if (h_mode != 2'd0)               verdict = E_MODE;",
     "    else if (1'b0)                         verdict = E_MODE;",
     "abi-v2"),
    ("ABI-02 engine policy ignored: every job treated as AUTO", "sys/rtl/hydra_abi_v2.sv",
     "  wire [NENG-1:0] elig = policy_mask(h_pol) & PRESENT[NENG-1:0] & healthy;",
     "  wire [NENG-1:0] elig = policy_mask(3'd0) & PRESENT[NENG-1:0] & healthy;",
     "systile-abi"),
    ("ABI-03 eligibility applied after cost, not before (the scheduler ignores the mask)", "mom/rtl/mom_top.sv",
     "    .cost(cost_q), .valid(ccapable_q & ~engine_full & eng_elig), .capable(ccapable_q & eng_elig),",
     "    .cost(cost_q), .valid(ccapable_q & ~engine_full), .capable(ccapable_q),",
     "systile-abi"),
    ("ABI-04 context epoch not compared: a revoked job runs", "sys/rtl/hydra_abi_v2.sv",
     "                (epoch[h_ctx[$clog2(NCTX)-1:0]] == h_epoch);",
     "                1'b1;",
     "abi-v2"),
    ("ABI-05 a second job taken before the first is dispatched", "sys/rtl/hydra_abi_v2.sv",
     "        S_SEND: if (out_ready) begin out_valid <= 1'b0; st <= S_WAIT; end",
     "        S_SEND: if (out_ready) begin out_valid <= 1'b0; st <= S_IDLE; end",
     "abi-v2"),
    # The Sixfold CPU wrapper (2026-10-18).
    ("CPU-01 done reported on the first cycle, not when the core halts", "sys/rtl/hydra_engine_cpu.sv",
     "          if (HALTED) begin",
     "          if (1'b1) begin",
     "cpu-quick"),
    ("CPU-02 a host memory write accepted while the core runs", "sys/rtl/hydra_engine_cpu.sv",
     "  wire host_owns  = eng_ready && !accept;",
     "  wire host_owns  = 1'b1;",
     "cpu-quick"),
    ("CPU-03 a launch with no program loaded is run", "sys/rtl/hydra_engine_cpu.sv",
     "  wire malformed = !loaded || (entry[1:0] != 2'd0) || (entry >= MEM_BYTES);",
     "  wire malformed = (entry[1:0] != 2'd0) || (entry >= MEM_BYTES);",
     "cpu-quick"),
    ("CPU-04 the cycle limit is never enforced", "sys/rtl/hydra_engine_cpu.sv",
     "          end else if (count + 32'd1 >= limit) begin",
     "          end else if (1'b0) begin",
     "cpu-quick"),
    ("CPU-05 engine 0's completion taken from the latency model, not the CPU", "sys/rtl/hydra_sys_tile.sv",
     "        assign eng_done[e]            = REAL_CPU ? cpu_done     : done_q;",
     "        assign eng_done[e]            = done_q;",
     "systile-cpu"),    # v3.11: the chip's spare pads (I2C target and GPIO)
    ("I2C-01 every address acknowledged, not only the target's", "common/rtl/hydra_i2c_gpio.sv",
     "                if (sh[7:1] == ADDR) begin",
     "                if (1'b1) begin",
     "i2c-gpio"),
    ("I2C-02 pointer not advanced after a written byte", "common/rtl/hydra_i2c_gpio.sv",
     "                ptr <= ptr_next; sda_oe <= 1'b1; st <= S_RXACK;",
     "                sda_oe <= 1'b1; st <= S_RXACK;",
     "i2c-gpio"),
    ("I2C-03 read data sent inverted", "common/rtl/hydra_i2c_gpio.sv",
     "              sda_oe <= !sh[6];",
     "              sda_oe <= sh[6];",
     "i2c-gpio"),
    ("I2C-04 the controller's NACK ignored: the target keeps sending", "common/rtl/hydra_i2c_gpio.sv",
     "            if (mack) begin",
     "            if (1'b1) begin",
     "i2c-gpio"),
    ("I2C-05 IN_HI reads the outputs, not the pads", "common/rtl/hydra_i2c_gpio.sv",
     "      8'h06:   rdata = {{(16-NGPIO){1'b0}}, i[NGPIO-1:8]};",
     "      8'h06:   rdata = {{(16-NGPIO){1'b0}}, o[NGPIO-1:8]};",
     "i2c-gpio"),
    ("I2C-06 OE_LO written into OUT_LO", "common/rtl/hydra_i2c_gpio.sv",
     "                  8'h03: gpio_oe[7:0]        <= sh;",
     "                  8'h03: gpio_out[7:0]       <= sh;",
     "i2c-gpio"),
    ("PAD-01 SDA pad drives high: not open drain", "sky130/rtl/hydra_openframe_top.sv",
     "  assign out_w     = {gpio_drv, 1'b0, 1'b0, pad_out, {P_FIRST{1'b0}}};",
     "  assign out_w     = {gpio_drv, 1'b1, 1'b0, pad_out, {P_FIRST{1'b0}}};",
     "sky130"),
    ("PAD-02 GPIO output enable not inverted for the active-low pad control", "sky130/rtl/hydra_openframe_top.sv",
     "  assign oeb_w     = {~gpio_e_w, ~sda_oe, 1'b1, ~pad_oe, {P_FIRST{1'b1}}};",
     "  assign oeb_w     = {gpio_e_w, ~sda_oe, 1'b1, ~pad_oe, {P_FIRST{1'b1}}};",
     "sky130"),
    ("I2C-07 mask revision bytes in the wrong order", "common/rtl/hydra_i2c_gpio.sv",
     "      8'h08:   rdata = mr[31:24];",
     "      8'h08:   rdata = mr[7:0];",
     "i2c-gpio"),
    ("I2C-08 a host-bus word is never written", "common/rtl/hydra_i2c_gpio.sv",
     "                    bus_wdata <= {wbuf, sh}; bus_we <= 1'b1;",
     "                    bus_wdata <= {wbuf, sh};",
     "i2c-gpio"),
    ("I2C-09 the host-bus address does not step after a written word", "common/rtl/hydra_i2c_gpio.sv",
     "      if (bus_we && !bus_hold) bus_addr <= bus_addr + 16'd1;   // the word was written: next one",
     "      if (1'b0) bus_addr <= bus_addr + 16'd1;",
     "i2c-gpio"),
    # v67: the CPU's console UART, LEDs and the GPIO owner
    ("UART-01 bits shifted out MSB first", "sys/rtl/hydra_engine_cpu.sv",
     "        tx_count <= '0; tx_shift <= {1'b1, tx_shift[9:1]}; tx_bits <= tx_bits - 4'd1;",
     "        tx_count <= '0; tx_shift <= {tx_shift[8:0], 1'b1}; tx_bits <= tx_bits - 4'd1;",
     "cpu-uart"),
    ("UART-02 no stop bit: the frame ends low", "sys/rtl/hydra_engine_cpu.sv",
     "          tx_shift <= {1'b1, uq[uq_rp[QW-1:0]], 1'b0};",
     "          tx_shift <= {1'b0, uq[uq_rp[QW-1:0]], 1'b0};",
     "cpu-uart"),
    ("UART-03 a PUTCHAR store never queued", "sys/rtl/hydra_engine_cpu.sv",
     "        else begin uq[uq_wp[QW-1:0]] <= dcache_din[7:0]; uq_wp <= uq_wp + 1'b1; end",
     "        else begin uq[uq_wp[QW-1:0]] <= dcache_din[7:0]; end",
     "cpu-uart"),
    ("UART-04 the queue never advances: the first byte sent again and again", "sys/rtl/hydra_engine_cpu.sv",
     "          uq_rp <= uq_rp + 1'b1; tx_bits <= 4'd10; tx_count <= '0;",
     "          tx_bits <= 4'd10; tx_count <= '0;",
     "cpu-uart"),
    ("LED-01 the LEDS register's high byte never written", "sys/rtl/hydra_engine_cpu.sv",
     "        if (dcache_we[1]) gpio_out[15:8] <= dcache_din[15:8];",
     "        if (1'b0) gpio_out[15:8] <= dcache_din[15:8];",
     "cpu-uart"),
    ("I2C-10 OWNER (0x0D) never written", "common/rtl/hydra_i2c_gpio.sv",
     "                  8'h0D: owner               <= sh[1:0];",
     "                  8'h0D: ;",
     "i2c-gpio"),
    ("PAD-03 the CPU's UART not routed to GPIO 0 when OWNER[0] is set", "sky130/rtl/hydra_openframe_top.sv",
     "                      gpio_owner[0] ? cpu_uart_tx : gpio_o[0]};",
     "                      gpio_o[0]};",
     "sky130-mcu"),
    # v68: every input pin read, the control space fully decoded
    ("PINS-01 the PINS register reads uio_in in place of the spare ui_in bits", "sys/rtl/hydra_sys_tile.sv",
     "    else begin pins_meta <= {ena, ui_in[7:3], uio_in}; pins_q <= pins_meta; end",
     "    else begin pins_meta <= {ena, uio_in[7:3], uio_in}; pins_q <= pins_meta; end",
     "sky130-mcu"),
    ("DEC-01 control-space writes ignore address bits [13:4]", "sys/rtl/hydra_sys_tile.sv",
     " && (mem_addr[15:14] == 2'd3) && (mem_addr[13:4] == 10'd0);",
     " && (mem_addr[15:14] == 2'd3);",
     "sky130-mcu"),
    ("DEC-02 control-space reads ignore address bits [13:4]", "sys/rtl/hydra_sys_tile.sv",
     "((mem_raddr[13:4] == 10'd0) ? ctl_rdata : 32'd0)",
     "ctl_rdata",
     "sky130-mcu"),
    # the CPU's dispatch port
    ("DP-01 the CPU is eligible for work it submitted itself", "sys/rtl/hydra_sys_tile.sv",
     "        .healthy(healthy_q & {{(NENG-1){1'b1}}, cpu_boot_ok && !sel_cpu}));",
     "        .healthy(healthy_q & {{(NENG-1){1'b1}}, cpu_boot_ok}));",
     "systile-disp"),
    ("DP-02 a completed job of the CPU's is never counted", "sys/rtl/hydra_sys_tile.sv",
     "        cd_completed <= cd_completed + 16'd1;",
     "        cd_completed <= cd_completed;",
     "systile-disp"),
    ("DP-03 a store to SUBMIT is ignored", "sys/rtl/hydra_engine_cpu.sv",
     "        if (dcache_addr == MMIO_SUBMIT && !disp_valid) disp_valid <= 1'b1;",
     "        if (1'b0) disp_valid <= 1'b1;",
     "systile-disp"),
    ("DP-04 DESC_HI written into the low half of the descriptor", "sys/rtl/hydra_engine_cpu.sv",
     "          if (dcache_addr == MMIO_DESC_HI) disp_wd[64 + 8*b +: 8] <= dcache_din[8*b +: 8];",
     "          if (dcache_addr == MMIO_DESC_HI) disp_wd[8*b +: 8] <= dcache_din[8*b +: 8];",
     "systile-disp"),
    # secure boot of the chip's CPU
    ("SB-01 the digest is not compared: any image verifies", "sec/rtl/hydra_secure_boot.sv",
     "            if (digest == GOLDEN) verified <= 1'b1;",
     "            if (1'b1) verified <= 1'b1;",
     "secure-boot"),
    ("SB-02 the load port is open while the image is being hashed", "sec/rtl/hydra_secure_boot.sv",
     "  assign lock_load  = verified || busy;",
     "  assign lock_load  = verified;",
     "secure-boot"),
    ("SB-03 debug and memory reads not locked after a verified boot", "sec/rtl/hydra_secure_boot.sv",
     "  assign lock_debug = verified;",
     "  assign lock_debug = 1'b0;",
     "secure-boot"),
    ("SB-04 the image length is not checked", "sec/rtl/hydra_secure_boot.sv",
     "  wire len_ok = (boot_len != '0) && (boot_len <= (AW+1)'(1 << AW));",
     "  wire len_ok = 1'b1;",
     "secure-boot"),
    ("SB-05 image words hashed in the wrong byte order", "sec/rtl/hydra_secure_boot.sv",
     "  wire [31:0] be_word = {rd_data[7:0], rd_data[15:8], rd_data[23:16], rd_data[31:24]};",
     "  wire [31:0] be_word = rd_data;",
     "secure-boot"),
    ("SB-06 the CPU is eligible before its image is verified", "sys/rtl/hydra_sys_tile.sv",
     "  wire         cpu_boot_ok = !SBOOT || sb_verified;",
     "  wire         cpu_boot_ok = 1'b1;",
     "systile-boot"),
    ("SB-07 host writes into CPU memory accepted after a verified boot", "sys/rtl/hydra_sys_tile.sv",
     "        .ld_we(cpu_wr && !sb_lock_load),",
     "        .ld_we(cpu_wr),",
     "systile-boot"),
    ("SB-08 CPU registers readable after a verified boot", "sys/rtl/hydra_sys_tile.sv",
     "      4'd2:    ctl_rdata = sb_lock_debug ? 32'd0 : cpu_dbg[31:0];",
     "      4'd2:    ctl_rdata = cpu_dbg[31:0];",
     "systile-boot"),
    ("SB-09 the entry point can be moved after a verified boot", "sys/rtl/hydra_sys_tile.sv",
     "((mem_addr[3:0] == 4'd8 && !sb_lock_load) || mem_addr[3:0] == 4'd9)",
     "((mem_addr[3:0] == 4'd8) || mem_addr[3:0] == 4'd9)",
     "systile-boot"),
]


def copy_repo(dst):
    # "runs": LibreLane harden runs (sky130/harden/*/runs) are gigabytes, are
    # written to while a harden is going, and no mutation reads them
    shutil.copytree(ROOT, dst, ignore=shutil.ignore_patterns(
        ".git", "build", "sim_build", "__pycache__", "*.vcd", "vendor_refs", "*_prove", "*_cover", "runs"))
    # build/ext holds fetched inputs, not outputs: the SRAM macro's model that
    # make sram-model downloads where there is no PDK (the CI runner). Without it
    # the copy's sky130-mcu baseline fails and no mutation counts (CI, 2026-11-16).
    ext = ROOT / "build/ext"
    if ext.is_dir():
        shutil.copytree(ext, pathlib.Path(dst) / "build/ext")


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
