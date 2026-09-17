#!/usr/bin/env python3
"""
hydra_bind.py -- generate a board top and its constraints from a board file
                 and a plan, checked against the REAL port list of the RTL.

WHY IT READS THE RTL
  A top level that repeats a module's port list is a copy of something that
  lives somewhere else, and nothing keeps the copy honest -- the stale-anchor
  pattern that cost four silent verification gaps (s135, s136, s178, s178m).
  So the port list is extracted from the sources with yosys at build time, and
  a plan that names a port that does not exist, leaves an input undriven, or
  double-books a board pin is a hard error before anything is written.

  `check` regenerates into memory and diffs against the committed files, so a
  hand-edit of a generated top is caught in CI rather than on the bench.

USAGE
  hydra_bind.py ports  --plan P                 list the core's real ports
  hydra_bind.py build  --plan P [--out DIR]     write top + constraints + build
  hydra_bind.py check  --plan P                 fail if the committed files differ

PLAN (see plans/*.yaml)
  core:      module name to instantiate
  sources:   SystemVerilog files (relative to the repo root)
  board:     board file name in fpga/boards
  sys_hz:    the frequency the design is timed at. Never exceeded: the PLL
             solver picks the highest achievable value <= this.
  baud:      UART baud for the harness (optional)
  clock/reset: core port names
  ties:      port -> constant, for inputs no pin drives
  pins:      list of {core:, board:, dir:, invert:} mappings; `core` may be a
             bit, a range, or a whole port, and `board` likewise.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import tempfile
import sys

import yaml

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
BOARDS = ROOT / "fpga" / "boards"

sys.path.insert(0, str(HERE))
import pllcalc  # noqa: E402


# --------------------------------------------------------------------- ports
def core_ports(sources, top):
    """Real port list from the RTL, via sv2v + yosys. {name: (dir, width)}

    sv2v first, for the same reason src/regen.sh uses it: the sources are
    SystemVerilog with packages and packed structs that yosys does not read
    directly. Running the same converter the tile ships means the ports seen
    here are the ports the hardened netlist will have.
    """
    files = [str(ROOT / s) for s in sources]
    conv = subprocess.run(["sv2v"] + files, capture_output=True, text=True)
    if conv.returncode:
        raise SystemExit("sv2v failed:\n" + conv.stderr[-2000:])
    flat = pathlib.Path(tempfile.mkdtemp()) / "flat.v"
    flat.write_text(conv.stdout)
    script = f"read_verilog {flat}; hierarchy -top {top}; proc -noopt; write_json /dev/stdout"
    p = subprocess.run(["yosys", "-q", "-p", script], capture_output=True, text=True)
    if p.returncode:
        raise SystemExit("yosys failed while reading the design:\n" + p.stderr[-2000:])
    j = json.loads(p.stdout[p.stdout.index("{"):])
    mod = j["modules"][top]
    return {n: (v["direction"].lower(), len(v["bits"])) for n, v in mod["ports"].items()}


# ----------------------------------------------------------------- expansion
def m_reads(entry):
    return bool(entry.get("in"))


BIT = re.compile(r"^([A-Za-z_][\w$]*)(?:\[(\d+)(?::(\d+))?\])?$")


def expand(expr, widths, what):
    m = BIT.match(expr.strip())
    if not m:
        raise SystemExit(f"{what}: cannot parse {expr!r}")
    name, hi, lo = m.group(1), m.group(2), m.group(3)
    if name not in widths:
        near = ", ".join(sorted(k for k in widths if k.lower().startswith(name.lower()[:3]))[:6])
        raise SystemExit(f"{what}: {name!r} is not a {'port' if 'port' in what else 'pin'}"
                         + (f". Did you mean: {near}?" if near else ""))
    w = widths[name]
    if hi is None:
        return [f"{name}[{i}]" if w > 1 else name for i in range(w - 1, -1, -1)]
    hi = int(hi)
    lo = hi if lo is None else int(lo)
    step = -1 if hi >= lo else 1
    idx = list(range(hi, lo + step, step))
    for i in idx:
        if i >= w:
            raise SystemExit(f"{what}: {name}[{i}] is out of range (width {w})")
    return [f"{name}[{i}]" if w > 1 else name for i in idx]


# ------------------------------------------------------------------- emitters
def pll_block(vendor, board, sys_hz):
    fin = board["clock"]["hz"]
    sol = pllcalc.solve(vendor, fin, sys_hz, board.get("pll_device"))
    p = sol["params"]
    if sol.get("bypass"):
        body = ("  assign sys_clk  = clk_in;\n"
                "  assign pll_lock = 1'b1;\n")
    elif vendor == "ice40":
        body = (f"  SB_PLL40_PAD #(.FEEDBACK_PATH(\"SIMPLE\"), .DIVR(4'd{p['DIVR']}),\n"
                f"    .DIVF(7'd{p['DIVF']}), .DIVQ(3'd{p['DIVQ']}),\n"
                f"    .FILTER_RANGE(3'd{p['FILTER_RANGE']})) u_pll (\n"
                "    .PACKAGEPIN(clk_in), .PLLOUTCORE(sys_clk), .LOCK(pll_lock),\n"
                "    .RESETB(1'b1), .BYPASS(1'b0));\n")
    elif vendor == "ecp5":
        body = (f"  EHXPLLL #(.CLKI_DIV({p['CLKI_DIV']}), .CLKFB_DIV({p['CLKFB_DIV']}),\n"
                f"    .CLKOP_DIV({p['CLKOP_DIV']}), .CLKOP_CPHASE({p['CLKOP_CPHASE']}),\n"
                "    .CLKOP_ENABLE(\"ENABLED\"), .FEEDBK_PATH(\"CLKOP\"),\n"
                "    .PLLRST_ENA(\"DISABLED\"), .INTFB_WAKE(\"DISABLED\"),\n"
                "    .STDBY_ENABLE(\"DISABLED\"), .DPHASE_SOURCE(\"DISABLED\")) u_pll (\n"
                "    .RST(1'b0), .STDBY(1'b0), .CLKI(clk_in), .CLKOP(sys_clk),\n"
                "    .CLKFB(sys_clk), .LOCK(pll_lock),\n"
                "    .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b0),\n"
                "    .PHASESTEP(1'b0), .PHASELOADREG(1'b0), .ENCLKOP(1'b0));\n")
    elif vendor == "xilinx7":
        body = (f"  wire fb, clk_raw;\n"
                f"  MMCME2_BASE #(.CLKIN1_PERIOD({p['CLKIN1_PERIOD']}),\n"
                f"    .DIVCLK_DIVIDE({p['DIVCLK_DIVIDE']}),\n"
                f"    .CLKFBOUT_MULT_F({p['CLKFBOUT_MULT_F']}.0),\n"
                f"    .CLKOUT0_DIVIDE_F({p['CLKOUT0_DIVIDE_F']}.0)) u_pll (\n"
                "    .CLKIN1(clk_in), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(clk_raw),\n"
                "    .LOCKED(pll_lock), .PWRDWN(1'b0), .RST(1'b0));\n"
                "  BUFG u_bufg (.I(clk_raw), .O(sys_clk));\n")
    elif vendor == "gowin":
        body = (f"  rPLL #(.FCLKIN(\"{p['FCLKIN']}\"), .DEVICE(\"{p['DEVICE']}\"),\n"
                f"    .IDIV_SEL({p['IDIV_SEL']}), .FBDIV_SEL({p['FBDIV_SEL']}),\n"
                f"    .ODIV_SEL({p['ODIV_SEL']}), .DYN_SDIV_SEL(2), .CLKFB_SEL(\"internal\"))\n"
                "  u_pll (.CLKIN(clk_in), .CLKOUT(sys_clk), .LOCK(pll_lock),\n"
                "    .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0), .FBDSEL(6'b0),\n"
                "    .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),\n"
                "    .CLKOUTP(), .CLKOUTD(), .CLKOUTD3());\n")
    elif vendor == "intel":
        body = (f"  altpll #(.clk0_multiply_by({p['clk0_multiply_by']}),\n"
                f"    .clk0_divide_by({p['clk0_divide_by']}),\n"
                f"    .inclk0_input_frequency({p['inclk0_input_frequency']}),\n"
                "    .operation_mode(\"NORMAL\")) u_pll (\n"
                "    .inclk({1'b0, clk_in}), .clk(pll_out), .locked(pll_lock));\n"
                "  assign sys_clk = pll_out[0];\n")
    else:
        raise SystemExit(f"no PLL support for vendor {vendor!r}")
    return sol, body


def emit_top(plan, board, ports, mapped, sol, module):
    v = board["vendor"]
    lines = [f"// GENERATED by tools/hydra_bind.py -- do not edit.",
             f"// plan {plan['_name']}  board {board['name']}  core {plan['core']}",
             f"// clock {board['clock']['hz'] / 1e6:g} MHz -> {sol['fout']:g} MHz"
             f" ({'direct' if sol.get('bypass') else v + ' PLL'}), requested"
             f" {plan['sys_hz'] / 1e6:g} MHz",
             "`default_nettype none", "", f"module {module} ("]

    board_ports = []
    if "port_p" in board["clock"]:
        board_ports += [f"  input  wire {board['clock']['port_p']}",
                        f"  input  wire {board['clock']['port_n']}"]
    else:
        board_ports.append(f"  input  wire {board['clock']['port']}")
    board_ports.append(f"  input  wire {sanitize(board['reset']['port'])}")
    # One port per MAPPED pin, not per header. Declaring a whole 28-bit header
    # to use nine of it leaves nineteen outputs undriven and floating on the
    # board.
    seen = {}
    for m in mapped:
        seen.setdefault(sanitize(m["board"]), m["dir"])
    for name, d in seen.items():
        kw = {"input": "input  wire", "output": "output wire", "inout": "inout  wire"}[d]
        board_ports.append(f"  {kw} {name}")
    lines.append(",\n".join(board_ports))
    lines += [");", "", "  wire sys_clk, pll_lock;"]

    if "port_p" in board["clock"]:
        lines += ["  wire clk_in;",
                  f"  IBUFDS u_ibufds (.I({board['clock']['port_p']}), "
                  f".IB({board['clock']['port_n']}), .O(clk_in));"]
    else:
        lines.append(f"  wire clk_in = {board['clock']['port']};")
    lines += ["", sol["_body"], ""]

    rst_port = sanitize(board["reset"]["port"])
    pol = "" if board["reset"]["active"] == "low" else "~"
    lines += [f"  wire board_rst_n = {pol}{rst_port} & pll_lock;",
              "  wire sys_rst_n;",
              "  hydra_rst_sync u_rst (.clk(sys_clk), .arst_n(board_rst_n),",
              "    .scan_mode(1'b0), .scan_rst_n(1'b1), .rst_n(sys_rst_n));", ""]

    # nets for every core port
    for name, (d, w) in sorted(ports.items()):
        rng = f"[{w - 1}:0] " if w > 1 else ""
        lines.append(f"  wire {rng}c_{name};")
    lines.append("")

    # tie-offs
    for port, val in (plan.get("ties") or {}).items():
        if port not in ports:
            raise SystemExit(f"tie {port!r} is not a port of {plan['core']}")
        w = ports[port][1]
        lines.append(f"  assign c_{port} = {w}'d{val};")
    lines.append(f"  assign c_{plan['clock']} = sys_clk;")
    lines.append(f"  assign c_{plan['reset']} = sys_rst_n;")
    lines.append("")

    # pin connections
    for m in mapped:
        b, c, d = sanitize(m["board"]), m["core"], m["dir"]
        inv = "~" if m.get("invert") else ""
        if d == "input":
            lines.append(f"  assign c_{c} = {inv}{b};")
        elif d == "output":
            lines.append(f"  assign {b} = {inv}c_{c};")
        else:
            oe = m["oe"]
            lines.append(f"  assign {b} = c_{oe} ? {inv}c_{c} : 1'bz;")
            if m.get("in"):
                lines.append(f"  assign c_{m['in']} = {inv}{b};")
    lines.append("")

    conns = ",\n".join(f"    .{n}(c_{n})" for n in sorted(ports))
    lines += [f"  {plan['core']} u_core (", conns, "  );", "", "endmodule",
              "`default_nettype wire", ""]
    return "\n".join(lines)


def sanitize(n):
    return re.sub(r"[\[\]]", lambda m: "_" if m.group(0) == "[" else "", n)


def emit_constraints(plan, board, mapped):
    v, fmt = board["vendor"], {"xilinx7": "xdc", "ice40": "pcf", "ecp5": "lpf",
                               "gowin": "cst", "intel": "qsf"}[board["vendor"]]
    period_ns = 1e9 / board["clock"]["hz"]
    out = [f"# GENERATED by tools/hydra_bind.py from fpga/boards/{board['name']}.yaml"]
    items = []
    if "port_p" in board["clock"]:
        items += [(board["clock"]["port_p"], board["clock"]["pin_p"]),
                  (board["clock"]["port_n"], board["clock"]["pin_n"])]
    else:
        items.append((board["clock"]["port"], board["clock"]["pin"]))
    items.append((sanitize(board["reset"]["port"]), board["reset"]["pin"]))
    for m in mapped:
        items.append((sanitize(m["board"]), m["pin"]))

    for port, pin in items:
        io = pin.get("iostandard", "LVCMOS33")
        p = pin["pin"]
        if fmt == "xdc":
            out.append(f"set_property -dict {{ PACKAGE_PIN {p} IOSTANDARD {io} }} "
                       f"[get_ports {{ {port} }}]")
        elif fmt == "pcf":
            out.append(f"set_io {port} {p}")
        elif fmt == "lpf":
            out.append(f'LOCATE COMP "{port}" SITE "{p}";')
            out.append(f'IOBUF PORT "{port}" IO_TYPE={io};')
        elif fmt == "cst":
            out.append(f'IO_LOC "{port}" {p};')
            out.append(f'IO_PORT "{port}" IO_TYPE={io};')
        elif fmt == "qsf":
            out.append(f"set_location_assignment PIN_{p} -to {port}")
            out.append(f'set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {port}')

    clk_port = board["clock"].get("port_p") or board["clock"]["port"]
    if fmt == "xdc":
        out.append(f"create_clock -period {period_ns:.3f} -name sys_clk_pin [get_ports {{ {clk_port} }}]")
    elif fmt == "pcf":
        out.append(f"# clock frequency is set in the nextpnr call: --freq {plan['sys_hz'] / 1e6:g}")
    elif fmt == "lpf":
        out.append(f'FREQUENCY PORT "{clk_port}" {board["clock"]["hz"] / 1e6:g} MHZ;')
    elif fmt == "cst":
        out.append(f"// clock period {period_ns:.3f} ns; see the generated .sdc")
    return "\n".join(out) + "\n", fmt


def emit_build(plan, board, module, sol, srcs):
    v = board["vendor"]
    if v in ("ice40", "ecp5"):
        if v == "ice40":
            synth = f"synth_ice40 -top {module} -json {module}.json"
            pnr = (f"nextpnr-ice40 --{board['device']} --package {board['package']} "
                   f"--json {module}.json --pcf {module}.pcf --asc {module}.asc "
                   f"--freq {plan['sys_hz'] / 1e6:g}")
            pack = f"icepack {module}.asc {module}.bin"
        else:
            synth = f"synth_ecp5 -top {module} -json {module}.json"
            pnr = (f"nextpnr-ecp5 {board['nextpnr_device']} --package {board['package']} "
                   f"--json {module}.json --lpf {module}.lpf --textcfg {module}.config "
                   f"--freq {plan['sys_hz'] / 1e6:g}")
            pack = f"ecppack {module}.config {module}.bit"
        mid = "asc" if v == "ice40" else "config"
        out = "bin" if v == "ice40" else "bit"
        return (f"# GENERATED by tools/hydra_bind.py\n"
                f"SRC = {' '.join(srcs)}\n\n"
                f"all: {module}.{out}\n\n"
                f"{module}.v: $(SRC)\n\tsv2v $(SRC) > $@\n\n"
                f"{module}.json: {module}.v\n\tyosys -p 'read_verilog $<; {synth}'\n\n"
                f"{module}.{mid}: {module}.json\n\t{pnr}\n\n"
                f"{module}.{out}: {module}.{mid}\n\t{pack}\n\n"
                f"clean:\n\trm -f {module}.v {module}.json {module}.{mid} {module}.{out}\n")
    if v == "xilinx7":
        return (f"# GENERATED by tools/hydra_bind.py -- Vivado batch script\n"
                f"# vivado -mode batch -source build.tcl\n"
                + "".join(f"read_verilog -sv {s}\n" for s in srcs) +
                f"read_xdc {module}.xdc\n"
                f"synth_design -top {module} -part {board['device']}\n"
                f"opt_design\nplace_design\nroute_design\n"
                f"report_timing_summary -file {module}_timing.rpt\n"
                f"report_utilization -file {module}_util.rpt\n"
                f"write_bitstream -force {module}.bit\n")
    if v == "intel":
        return (f"# GENERATED by tools/hydra_bind.py -- Quartus project\n"
                f"set_global_assignment -name FAMILY \"{board['family']}\"\n"
                f"set_global_assignment -name DEVICE {board['device']}\n"
                f"set_global_assignment -name TOP_LEVEL_ENTITY {module}\n"
                + "".join(f"set_global_assignment -name SYSTEMVERILOG_FILE {s}\n" for s in srcs)
                + f"source {module}.qsf.pins\n")
    if v == "gowin":
        return (f"# GENERATED by tools/hydra_bind.py -- open flow (apicula)\n"
                f"SRC = {' '.join(srcs)}\n\n"
                f"all: {module}.fs\n\n"
                f"{module}.v: $(SRC)\n\tsv2v $(SRC) > $@\n\n"
                f"{module}.json: {module}.v\n\tyosys -p 'read_verilog $<; "
                f"synth_gowin -top {module} -json $@'\n\n"
                f"{module}_pnr.json: {module}.json\n\tnextpnr-himbaechel --device "
                f"'{board['device']}' --json $< --write $@ --vopt cst={module}.cst\n\n"
                f"{module}.fs: {module}_pnr.json\n\tgowin_pack -d "
                f"'{board['device']}' -o $@ $<\n")
    raise SystemExit(f"no build script for vendor {board['vendor']!r}")


# ---------------------------------------------------------------------- main
def load(plan_path):
    plan = yaml.safe_load(pathlib.Path(plan_path).read_text())
    plan["_name"] = pathlib.Path(plan_path).name
    board = yaml.safe_load((BOARDS / f"{plan['board']}.yaml").read_text())
    return plan, board


def resolve(plan, board, ports):
    bwidth = {}
    for name in board["pins"]:
        if "[" in name:
            base, idx = name.split("[")
            bwidth[base] = max(bwidth.get(base, 0), int(idx[:-1]) + 1)
        else:
            bwidth[name] = 1
    plan["_bwidth"] = bwidth
    pin_of = {k: v for k, v in board["pins"].items()}

    used_board, driven = {}, {}
    mapped = []
    for entry in plan["pins"]:
        core = expand(entry["core"], {k: v[1] for k, v in ports.items()},
                      f"plan {plan['_name']} core port")
        brd = expand(entry["board"], bwidth, f"plan {plan['_name']} board pin")
        if len(core) != len(brd):
            raise SystemExit(f"{entry['core']} is {len(core)} bits but "
                             f"{entry['board']} is {len(brd)}")
        oe = expand(entry["oe"], {k: v[1] for k, v in ports.items()}, "oe") if entry.get("oe") else None
        din = expand(entry["in"], {k: v[1] for k, v in ports.items()}, "in") if entry.get("in") else None
        for i, (c, b) in enumerate(zip(core, brd)):
            base = c.split("[")[0]
            d = entry.get("dir") or ports[base][0]
            if b in used_board:
                raise SystemExit(f"board pin {b} is used twice ({used_board[b]} and {c})")
            used_board[b] = c
            role = pin_of[b].get("role", "io")
            if d in ("output", "inout") and role == "in":
                raise SystemExit(f"plan {plan['_name']}: {c} would drive {b}, which is "
                                 f"an input-only pin on this board (a switch, button "
                                 f"or receive line)")
            if (d == "input" or m_reads(entry)) and role == "out":
                raise SystemExit(f"plan {plan['_name']}: {c} would read {b}, which is "
                                 f"an output-only pin on this board (an LED or a "
                                 f"transmit line)")
            if d in ("output", "inout") and ports[base][0] != "output":
                raise SystemExit(f"{c} is an {ports[base][0]}, cannot drive pin {b}")
            if d == "input":
                driven[c] = b
            if din:
                driven[din[i]] = b
            mapped.append(dict(core=c, board=b, board_base=b.split("[")[0], dir=d,
                               pin=pin_of[b], invert=entry.get("invert", False),
                               oe=oe[i] if oe else None, **({"in": din[i]} if din else {})))

    # every core input must be driven by a pin or a tie
    ties = set(plan.get("ties") or {})
    missing = []
    for name, (d, w) in ports.items():
        if d != "input" or name in ties or name in (plan["clock"], plan["reset"]):
            continue
        bits = [f"{name}[{i}]" if w > 1 else name for i in range(w)]
        if not all(b in driven for b in bits):
            missing.append(name)
    if missing:
        raise SystemExit(f"plan {plan['_name']}: these inputs of {plan['core']} are "
                         f"neither mapped nor tied: {', '.join(sorted(missing))}")
    return mapped


def generate(plan, board, out):
    ports = core_ports(plan["sources"], plan["core"])
    for p in (plan["clock"], plan["reset"]):
        if p not in ports:
            raise SystemExit(f"{p!r} is not a port of {plan['core']}")
    mapped = resolve(plan, board, ports)
    module = plan.get("module") or f"hydra_{board['name'].replace('-', '_')}_top"
    sol, body = pll_block(board["vendor"], board, plan["sys_hz"])
    sol["_body"] = body
    top = emit_top(plan, board, ports, mapped, sol, module)
    cons, fmt = emit_constraints(plan, board, mapped)
    # Paths in the build script are relative to the build directory, computed
    # rather than assumed: a hand-written "../../" breaks the moment --out moves.
    rel = os.path.relpath(ROOT, out)
    srcs = [f"{rel}/{s}" for s in plan["sources"]] + [
        f"{rel}/common/rtl/hydra_rst_sync.sv", f"{module}.sv"]
    build = emit_build(plan, board, module, sol, srcs)
    files = {f"{module}.sv": top, f"{module}.{fmt}": cons,
             ("build.tcl" if board["vendor"] == "xilinx7" else
              "project.qsf" if board["vendor"] == "intel" else "Makefile"): build}
    return module, sol, files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["ports", "build", "check"])
    ap.add_argument("--plan", required=True)
    ap.add_argument("--out")
    a = ap.parse_args()
    plan, board = load(a.plan)

    if a.cmd == "ports":
        for n, (d, w) in sorted(core_ports(plan["sources"], plan["core"]).items()):
            print(f"  {d:6s} [{w - 1}:0] {n}" if w > 1 else f"  {d:6s}        {n}")
        return

    out = pathlib.Path(a.out or (ROOT / "fpga" / "build" / f"{plan['board']}"))
    module, sol, files = generate(plan, board, out)
    if a.cmd == "build":
        out.mkdir(parents=True, exist_ok=True)
        for name, text in files.items():
            (out / name).write_text(text)
        hz = sol["fout"] * 1e6
        print(f"{plan['board']}: {module} at {hz / 1e6:g} MHz "
              f"({'oscillator direct' if sol.get('bypass') else 'PLL ' + str(sol['params'])})")
        print(f"  wrote {', '.join(sorted(files))} to {out}")
    else:
        bad = [n for n, t in files.items()
               if not (out / n).exists() or (out / n).read_text() != t]
        if bad:
            print(f"DRIFT in {out}: {', '.join(bad)}")
            sys.exit(1)
        print(f"{plan['board']}: generated files match the plan and the RTL")


if __name__ == "__main__":
    main()
