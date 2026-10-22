#!/usr/bin/env python3
"""
atlas_traces.py -- record the traces the Silicon Atlas replays.

Every animation on the project page that claims to show the hardware replays
one of these files. Each is cut from a value change dump (VCD) of a test that
PASSED, on the source files whose hashes it records, so a page can never
show a run that failed or a design that has since changed:

  tile-rtl   one test of the tile's own cocotb suite (tt/tile/test), run on
             the submitted RTL, tt/tile/src/project.v. "Recorded RTL Trace".
  (tile-gl)  the same test on a hardened netlist, "Gate-Level Trace":
             tile_run() can run it, but no trace is recorded yet; a netlist
             keeps only pins and some register names (docs/atlas/README.md).
  make       a chip-side make target, replayed with a dump module added; the
             testbench and its independent Python model are the target's own,
             and the run must pass scripts/runsim.sh. "Recorded RTL Trace".

The page interpolates between recorded values for smooth motion. That is
presentation: the cycle numbers shown are the recorded ones, and nothing
between two samples is a hardware state.

    python3 tools/atlas_traces.py                 every trace in docs/atlas/atlas.yaml
    python3 tools/atlas_traces.py crossover tags  only these
"""
import hashlib, json, os, pathlib, re, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import vcd                                     # noqa: E402

SPEC = ROOT / "docs/atlas/atlas.yaml"
OUTD = ROOT / "docs/atlas/traces"
TILE = ROOT / "tt/tile"
U = "tb.user_project"

# The signals a tile trace keeps. Everything else in the dump is dropped.
TILE_SIGNALS = {
    "clk": "tb.clk", "rst_n": "tb.rst_n", "ui_in": "tb.ui_in", "uo_out": "tb.uo_out",
    "uio_out": "tb.uio_out",
    "rst_sync": f"{U}.u_rst_sync.sync_q", "rst_core": f"{U}.rst_n_sync",
    "spi_cs_start": f"{U}.u_spi.cs_start", "spi_cs_end": f"{U}.u_spi.cs_end",
    "spi_rx_valid": f"{U}.u_spi.rx_valid", "spi_rx_byte": f"{U}.u_spi.rx_byte",
    "spi_rx_index": f"{U}.u_spi.rx_index", "spi_tx_load": f"{U}.u_spi.tx_load",
    "spi_tx_byte": f"{U}.u_spi.tx_byte",
    "reg_frame_ok": f"{U}.u_regs.frame_ok", "reg_frame_bad": f"{U}.u_regs.frame_bad",
    "reg_cmd_addr": f"{U}.u_regs.cmd_addr", "reg_cmd_rd": f"{U}.u_regs.cmd_rd",
    "reg_wd_ok": f"{U}.u_regs.wd_ok", "reg_do_go": f"{U}.u_regs.do_go",
    "reg_go_accept": f"{U}.u_regs.go_accept", "reg_pending": f"{U}.u_regs.pending_q",
    "reg_status": f"{U}.u_regs.status_w", "reg_hold": f"{U}.u_regs.hold_q",
    "wd_valid": f"{U}.u_mom.wd_valid", "wd_ready": f"{U}.u_mom.wd_ready",
    "wd": f"{U}.u_mom.wd",
    "f_valid": f"{U}.u_mom.f_valid", "f_lg_w": f"{U}.u_mom.f_lg_w", "f_lg_i": f"{U}.u_mom.f_lg_i",
    "eval_busy": f"{U}.u_mom.eval_busy", "idx": f"{U}.u_mom.g_shared.idx",
    "phase": f"{U}.u_mom.g_shared.phase", "lane_we": f"{U}.u_mom.lane_we",
    "lane_cost": f"{U}.u_mom.lane_cost", "lane_tpred": f"{U}.u_mom.lane_tpred",
    "lane_valid": f"{U}.u_mom.lane_valid", "lane_capable": f"{U}.u_mom.lane_capable",
    "ce_opc_ok": f"{U}.u_mom.g_shared.u_ce.opc_supported",
    "ce_dt_ok": f"{U}.u_mom.g_shared.u_ce.dt_supported",
    "ce_full": f"{U}.u_mom.g_shared.u_ce.engine_busy_full",
    "ce_k": f"{U}.u_mom.g_shared.u_ce.k_cal",
    "ce_qd": f"{U}.u_mom.g_shared.u_ce.queue_depth",
    "c_valid": f"{U}.u_mom.c_valid", "cost_q": f"{U}.u_mom.cost_q",
    "t_pred_q": f"{U}.u_mom.t_pred_q", "eng_full": f"{U}.u_mom.engine_full",
    "ccapable_q": f"{U}.u_mom.ccapable_q", "eng_elig": f"{U}.u_mom.eng_elig",
    "sel_eng": f"{U}.u_mom.sel_eng", "sel_ok": f"{U}.u_mom.sel_ok",
    "margin": f"{U}.u_mom.obs_margin", "unsupported": f"{U}.u_mom.unsupported",
    "sb_ready": f"{U}.u_mom.sb_ready", "disp_valid": f"{U}.u_mom.disp_valid",
    "disp_accept": f"{U}.u_mom.disp_accept", "disp_tag": f"{U}.u_mom.disp_tag",
    "disp_engine": f"{U}.u_mom.disp_engine",
    "sb_do_disp": f"{U}.u_mom.u_sb.do_disp", "sb_do_comp": f"{U}.u_mom.u_sb.do_comp",
    "sb_stale": f"{U}.u_mom.u_sb.stale_comp", "sb_now": f"{U}.u_mom.u_sb.now",
    "tag_busy": f"{U}.u_mom.u_sb.tag_busy_vec", "queue_depth": f"{U}.u_mom.u_sb.queue_depth",
    "comp_valid": f"{U}.u_mom.comp_valid", "comp_tag": f"{U}.u_mom.comp_tag",
    "cal_valid": f"{U}.u_mom.cal_valid", "cal_engine": f"{U}.u_mom.cal_engine",
    "cal_opclass": f"{U}.u_mom.cal_opclass", "cal_t_meas": f"{U}.u_mom.cal_t_meas",
    "cal_t_pred": f"{U}.u_mom.cal_t_pred",
    "cal_k_cur": f"{U}.u_mom.u_cal.k_cur", "cal_k_next": f"{U}.u_mom.u_cal.k_next",
    "cal_do_update": f"{U}.u_mom.u_cal.do_update", "cal_too_slow": f"{U}.u_mom.u_cal.too_slow",
    "cal_too_fast": f"{U}.u_mom.u_cal.too_fast", "cal_count": f"{U}.u_mom.u_cal.upd_count",
    "k_cal": f"{U}.u_mom.k_cal",
}


# What the waveform view draws, in order.
WAVE = ["rst_n", "rst_core", "ui_in", "uo_out", "uio_out", "spi_rx_valid", "reg_wd_ok",
        "wd_valid", "wd_ready", "eval_busy", "idx", "lane_we", "c_valid", "sel_eng",
        "sb_ready", "disp_valid", "disp_tag", "tag_busy", "comp_valid", "cal_valid"]


def run(cmd, cwd, env=None, timeout=1800):
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True,
                       env=env, timeout=timeout, executable="/bin/bash")
    return r.returncode, r.stdout + r.stderr


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def git_head(d):
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=d, capture_output=True,
                          text=True).stdout.strip()


def tool_versions():
    out = {}
    for name, cmd in (("iverilog", "iverilog -V 2>&1 | head -1"),
                      ("cocotb", "cocotb-config --version"), ("sv2v", "sv2v --numeric-version")):
        out[name] = subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()
    return out


# ---------------------------------------------------------------------------
# enums and the descriptor, read from the tile's own package
# ---------------------------------------------------------------------------
def enums(pkg):
    src = pathlib.Path(pkg).read_text()
    out = {}
    for body, name in re.findall(r"typedef enum logic \[\d+:0\] \{(.*?)\}\s*(\w+);", src, re.S):
        out[name] = {int(v, 0) if not "'" in v else int(v.split("'d")[1]): k
                     for k, v in re.findall(r"(\w+)\s*=\s*([\d']+d?\d*)", body)}
    return out


WD_FIELDS = [("op_class", 4), ("dtype", 3), ("lat_hint", 2), ("pwr_hint", 2), ("dim_m", 16),
             ("dim_n", 16), ("dim_k", 16), ("bytes", 24), ("src_loc", 2), ("tag", 8), ("reserved", 35)]


def check_wd_fields(pkg):
    """The field list above must be the package's work_desc_t, in order."""
    src = pathlib.Path(pkg).read_text()
    body = re.search(r"typedef struct packed \{(.*?)\}\s*work_desc_t;", src, re.S).group(1)
    names = re.findall(r"^\s*\w+(?:\s*\[[^\]]+\])?\s+(\w+);", body, re.M)
    if names != [f for f, _ in WD_FIELDS]:
        raise SystemExit(f"atlas_traces: work_desc_t changed in {pkg}: {names}")


def decode_wd(v):
    out, pos = {}, 128
    for name, w in WD_FIELDS:
        pos -= w
        out[name] = (v >> pos) & ((1 << w) - 1)
    return out


# ---------------------------------------------------------------------------
def tile_run(test, module, gl_netlist=None):
    """Run one cocotb test on the tile; return (vcd path, log, tmpdir)."""
    tmp = tempfile.mkdtemp(prefix="atlas_tr_")
    shutil.copytree(TILE / "test", f"{tmp}/test")
    args = f"SRC_DIR={TILE / 'src'} COCOTB_TEST_MODULES={module} COCOTB_TEST_FILTER='{test}$'"
    if gl_netlist:
        shutil.copy(gl_netlist, f"{tmp}/test/gate_level_netlist.v")
        args += " GATES=yes"
    rc, log = run(f"make -s {args}", f"{tmp}/test")
    ok = re.search(r"TESTS=1 PASS=1 FAIL=0", log)
    if rc or not ok:
        raise SystemExit(f"atlas_traces: {module}.{test} did not pass; refusing to record it.\n{log[-3000:]}")
    return f"{tmp}/test/tb.vcd", log, tmp


def timescale_ns(ts):
    """'1ps' -> 0.001, '1 ns' -> 1, '10ps' -> 0.01."""
    m = re.fullmatch(r"\s*(\d+)\s*(s|ms|us|ns|ps|fs)\s*", ts)
    if not m:
        raise SystemExit(f"atlas_traces: cannot read the VCD timescale {ts!r}")
    unit = {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1.0, "ps": 1e-3, "fs": 1e-6}[m.group(2)]
    return int(m.group(1)) * unit


def compact(sigs, names, edges):
    """Per signal: [[cycle, hex-or-x], ...]. Cycle c is the clock period that
    begins at rising edge c; a signal's value in it is the value it holds
    just before edge c+1, which is what every flip-flop samples at that
    edge. Registers then show the value they took at edge c, and a
    combinational strobe that is high during the cycle is seen, whether the
    testbench drives inputs just after an edge or on the falling edge."""
    import bisect
    out = {}
    period = edges[1] - edges[0]
    for short, full in names.items():
        if full not in sigs or short == "clk":
            continue
        ch = sigs[full]["changes"]
        w = sigs[full]["width"]
        series, last = [], None
        times = [t for t, _ in ch]
        for c, t in enumerate(edges):
            end = edges[c + 1] if c + 1 < len(edges) else t + period
            i = bisect.bisect_left(times, end) - 1
            v = ch[i][1] if i >= 0 else None
            if v != last:
                iv = vcd.as_int(v)
                series.append([c, "x" if iv is None else format(iv, "x")])
                last = v
        out[short] = {"w": w, "v": series}
    return out


class S:
    """Sampled signal values by cycle."""
    def __init__(self, comp):
        self.c = comp
        self.idx = {k: [c for c, _ in s["v"]] for k, s in comp.items()}

    def at(self, name, cyc):
        import bisect
        s = self.c.get(name)
        if not s:
            return None
        i = bisect.bisect_right(self.idx[name], cyc) - 1
        v = s["v"][i][1] if i >= 0 else None
        return None if v in (None, "x") else int(v, 16)

    def rises(self, name):
        s = self.c.get(name, {"v": []})["v"]
        return [c for c, x in s if x not in ("0", "x")]


def lanes(v, n, w):
    return [(v >> (w * i)) & ((1 << w) - 1) for i in range(n)] if v is not None else [None] * n


def tile_events(s, en, n_eng=5):
    """What happened, in order, read only from the recorded signals."""
    eng = en.get("engine_e", {})
    opc = en.get("opclass_e", {})
    dt = en.get("dtype_e", {})
    ev = []
    # SPI frames: bytes between cs_start and cs_end
    starts, ends = s.rises("spi_cs_start"), s.rises("spi_cs_end")
    rx = s.rises("spi_rx_valid")
    for a in starts:
        b = next((e for e in ends if e >= a), None)
        if b is None:
            continue
        bytes_ = [s.at("spi_rx_byte", c) for c in rx if a <= c <= b]
        if not bytes_:
            ev.append({"c": a, "k": "spi", "end": b, "bytes": [], "text": "empty frame (CS pulse, no bytes)"})
            continue
        cmd = bytes_[0]
        rd, addr = cmd >> 7, cmd & 0x7F
        # frame_ok / frame_bad are the register map's decode, evaluated on the
        # cs_end cycle (hydra_tt_regs.sv: commit = cs_end && frame_ok)
        tx = [s.at("spi_tx_byte", c) for c in s.rises("spi_tx_load") if a <= c <= b]
        ev.append({"c": a, "k": "spi", "end": b, "rd": rd, "addr": addr, "bytes": bytes_,
                   "cipo": tx, "ok": bool(s.at("reg_frame_ok", b)),
                   "bad": bool(s.at("reg_frame_bad", b))})
    for c in s.rises("reg_do_go"):
        ev.append({"c": c, "k": "go", "accepted": bool(s.at("reg_go_accept", c))})
    # descriptor into the MOM
    for c in range(0, 10**9):
        break
    wv = s.c.get("wd_valid", {"v": []})["v"]
    prev = None
    for c, x in wv:
        if x == "1":
            w = s.at("wd", c)
            if w is not None:
                d = decode_wd(w)
                ev.append({"c": c, "k": "desc", "wd": format(w, "032x"),
                           "op": opc.get(d["op_class"], str(d["op_class"])),
                           "dtype": dt.get(d["dtype"], str(d["dtype"])),
                           "m": d["dim_m"], "n": d["dim_n"], "kk": d["dim_k"], "bytes": d["bytes"],
                           "lat": d["lat_hint"], "pwr": d["pwr_hint"]})
    for c in s.rises("f_valid"):
        ev.append({"c": c, "k": "feat", "lg_w": s.at("f_lg_w", c),
                   "lg_i": (lambda v: v - 512 if v is not None and v >= 256 else v)(s.at("f_lg_i", c))})
    for c in s.rises("lane_we"):
        i = s.at("idx", c)
        ev.append({"c": c, "k": "lane", "eng": i, "name": eng.get(i, str(i)),
                   "cost": s.at("lane_cost", c), "tpred": s.at("lane_tpred", c),
                   "valid": s.at("lane_valid", c), "capable": s.at("lane_capable", c),
                   "opc_ok": s.at("ce_opc_ok", c), "dt_ok": s.at("ce_dt_ok", c),
                   "full": s.at("ce_full", c), "kf": s.at("ce_k", c), "qd": s.at("ce_qd", c)})
    for c in s.rises("c_valid"):
        costs = lanes(s.at("cost_q", c), n_eng, 32)
        # since v3.10 the selector reads the scoreboard's LIVE full flags
        # (mom_top.sv: valid = ccapable_q & ~engine_full & eng_elig)
        full = s.at("eng_full", c) or 0
        cap = s.at("ccapable_q", c) or 0
        val = cap & ~full
        el = s.at("eng_elig", c)
        el = (1 << n_eng) - 1 if el is None else el
        rows = []
        se = s.at("sel_eng", c)
        ok = s.at("sel_ok", c)
        for e in range(n_eng):
            why = None
            if not (el >> e) & 1:
                why = "not eligible"
            elif not (cap >> e) & 1:
                why = "cannot do this operation or data type"
            elif not (val >> e) & 1:
                why = "its queue is full this cycle"
            elif ok and e != se:
                why = "higher cost"
            rows.append({"eng": e, "name": eng.get(e, str(e)), "cost": costs[e],
                         "chosen": bool(ok and e == se), "why": why})
        ev.append({"c": c, "k": "select", "ok": bool(ok), "eng": se, "margin": s.at("margin", c),
                   "unsupported": bool(s.at("unsupported", c)), "rows": rows})
    for c in s.rises("sb_do_disp"):
        ev.append({"c": c, "k": "tag", "tag": s.at("disp_tag", c), "eng": s.at("disp_engine", c),
                   "busy_before": s.at("tag_busy", c - 1), "busy_after": s.at("tag_busy", c + 1)})
    for c in s.rises("comp_valid"):
        ev.append({"c": c, "k": "comp", "tag": s.at("comp_tag", c),
                   "stale": bool(s.at("sb_stale", c)), "busy_after": s.at("tag_busy", c + 1)})
    for c in s.rises("cal_valid"):
        e = s.at("cal_engine", c)
        ev.append({"c": c, "k": "cal", "eng": e, "name": eng.get(e, str(e)),
                   "opclass": opc.get(s.at("cal_opclass", c), "?"),
                   "meas": s.at("cal_t_meas", c), "pred": s.at("cal_t_pred", c),
                   "k_cur": s.at("cal_k_cur", c), "k_next": s.at("cal_k_next", c),
                   "update": bool(s.at("cal_do_update", c)), "slow": bool(s.at("cal_too_slow", c)),
                   "fast": bool(s.at("cal_too_fast", c))})
    for c in s.rises("unsupported"):
        ev.append({"c": c, "k": "unsupported"})
    # back-pressure: wd_ready falling while a descriptor is offered
    rv = s.c.get("wd_ready", {"v": []})["v"]
    for c, x in rv:
        if x == "0" and c > 0:
            ev.append({"c": c, "k": "stall", "what": "wd_ready low: the dispatcher takes no new descriptor this cycle"})
    for c, x in s.c.get("sb_ready", {"v": []})["v"]:
        if x == "0" and c > 0:
            ev.append({"c": c, "k": "notag", "what": "no free tag: the descriptor is held"})
    for c, x in s.c.get("rst_n", {"v": []})["v"]:
        ev.append({"c": c, "k": "reset", "level": x})
    for c, x in s.c.get("rst_core", {"v": []})["v"]:
        ev.append({"c": c, "k": "reset_sync", "level": x})
    ev.sort(key=lambda e: (e["c"], e["k"]))
    return ev


# ---------------------------------------------------------------------------
def record_tile(t, gl=None):
    vpath, log, tmp = tile_run(t["test"], t["module"], gl)
    try:
        sigs, ts, t_last = vcd.read(vpath, [re.escape(v) for v in TILE_SIGNALS.values()])
    finally:
        pass
    missing = [k for k, v in TILE_SIGNALS.items() if v not in sigs]
    if gl is None and missing:
        raise SystemExit(f"atlas_traces: signals missing from the dump: {missing}")
    edges = [tt for tt, v in sigs["tb.clk"]["changes"] if v == "1"]
    period = edges[1] - edges[0]
    comp = compact(sigs, TILE_SIGNALS, edges)
    pkg = TILE / "src/rtl/mom_pkg.sv"
    check_wd_fields(pkg)
    en = enums(pkg)
    events = tile_events(S(comp), en)
    shutil.rmtree(tmp, ignore_errors=True)
    # The page draws waveforms of a few signals; the rest were needed only to
    # read the events. A long trace keeps its events alone.
    keep = WAVE if t.get("wave", True) else []
    comp = {k: v for k, v in comp.items() if k in keep}
    srcs = [TILE / "src/project.v", TILE / f"test/{t['module']}.py", TILE / "test/tb.v"]
    passed = re.search(r"\*\* (\S+)\s+PASS\s+([\d.]+)", log)
    return {
        "id": t["id"], "label": "Gate-Level Trace" if gl else "Recorded RTL Trace",
        "title": t["title"], "caption": t.get("caption", ""),
        "test": f"tt/tile/test/{t['module']}.py::{t['test']}",
        "result": "PASS", "sim_time_ns": float(passed.group(2)) if passed else None,
        "command": (f"cd tt/tile/test && make COCOTB_TEST_MODULES={t['module']} "
                    f"COCOTB_TEST_FILTER={t['test']}" + (" GATES=yes" if gl else "")),
        "tile_commit": git_head(TILE), "repo_commit": git_head(ROOT),
        "tools": tool_versions(), "timescale": ts,
        "clock_ns": period * timescale_ns(ts),
        "cycles": len(edges),
        "enums": {k: {str(a): b for a, b in v.items()} for k, v in en.items()},
        "sources": {str(p.relative_to(ROOT)): sha(p) for p in srcs},
        "signals": comp, "events": events,
    }


# ---------------------------------------------------------------------------
# chip-side make targets: the target's own testbench and model, plus a dump
# ---------------------------------------------------------------------------
def make_run(t, tmp):
    """Replay `make <target>`: every command, in order, as make would run it,
    with a dump module compiled in and formal steps left out (they do not
    simulate). The simulation must pass scripts/runsim.sh as usual."""
    out = subprocess.run(["make", "-n", "-B", t["make"], f"SIMTMP={tmp}"], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout
    vcdf = f"{tmp}/atlas.vcd"
    dump = pathlib.Path(tmp) / "atlas_dump.v"
    dump.write_text("`timescale 1ns/1ps\nmodule atlas_dump;\n  initial begin\n"
                    f"    $dumpfile(\"{vcdf}\");\n    $dumpvars(0, {t['tb']}.{t.get('scope', 'dut')});\n"
                    f"    #{t.get('window_ns', 20000)} $dumpoff;\n  end\nendmodule\n")
    log = []
    for line in out.replace("\\\n", " ").splitlines():
        line = line.strip()
        if not line or "sby " in line or "--define=FORMAL" in line or line.startswith(("echo", "test ")):
            continue
        if re.search(r"(^|&&\s*)iverilog\b", line):
            line = re.sub(r"(iverilog\b[^|&;]*?-o\s+\S+)", rf"\1 {dump}", line, count=1)
        rc, o = run(line, ROOT)
        log.append(f"$ {line}\n{o}")
        if rc:
            raise SystemExit(f"atlas_traces: make {t['make']} failed while recording; refusing.\n" + "\n".join(log)[-3000:])
    if not any("runsim.sh" in l for l in log):
        raise SystemExit(f"atlas_traces: make {t['make']} ran no simulation through runsim.sh")
    return vcdf, "\n".join(log)


def record_make(t):
    tmp = tempfile.mkdtemp(prefix="atlas_mk_")
    try:
        vcdf, log = make_run(t, tmp)
        pats = [re.escape(f"{t['tb']}.") + p for p in t["signals"]] + [
            re.escape(f"{t['tb']}.{t[k]}") for k in ("start", "stop")]
        sigs, ts, _ = vcd.read(vcdf, pats + [re.escape(f"{t['tb']}.{t['clock']}")])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    clk = f"{t['tb']}.{t['clock']}"
    if clk not in sigs:
        raise SystemExit(f"atlas_traces: {t['id']}: clock {clk} not in the dump")
    edges = [tt for tt, v in sigs[clk]["changes"] if v == "1"]
    pref = f"{t['tb']}."
    names = {k[len(pref):]: k for k in sigs if k != clk}
    comp = compact(sigs, names, edges)
    # the window: from the first rise of `start` to `stop_after` cycles past the first rise of `stop`
    S0 = S(comp)
    want = t.get("select", {})       # e.g. a 4x4x4 job rather than the first, 1x1x1, one
    s0 = next((c for c, v in comp.get(t["start"], {"v": []})["v"] if v not in ("0", "x")
               and all(S0.at(k, c + 1) == val for k, val in want.items())), None)
    if s0 is None:
        raise SystemExit(f"atlas_traces: {t['id']}: no {t['start']} with {want} inside the dump window")
    s1 = next((c for c, v in comp.get(t["stop"], {"v": []})["v"] if v not in ("0", "x") and c >= s0), None)
    if s1 is None:
        raise SystemExit(f"atlas_traces: {t['id']}: {t['stop']} never rose after {t['start']}")
    a, b = max(0, s0 - 2), s1 + t.get("after", 3)
    win = {}
    for k, s in comp.items():
        before = [x for x in s["v"] if x[0] <= a]
        inside = [[c - a, v] for c, v in s["v"] if a < c <= b]
        win[k] = {"w": s["w"], "v": ([[0, before[-1][1]]] if before else []) + inside}
    meta = dict(t.get("meta", {}))
    if "states_from" in meta:
        f, sig = meta.pop("states_from")
        body = re.search(r"typedef enum logic \[\d+:0\] \{(.*?)\}", (ROOT / f).read_text(), re.S).group(1)
        meta["states"] = {"signal": f"dut.u_ctrl.{sig}", "names": re.findall(r"\b(S_\w+)", body)}
    if "q_from" in meta:
        f, name = meta.pop("q_from")
        m = re.search(rf"localparam\s+int\s+(?:unsigned\s+)?{name}\s*=\s*(\d+)", (ROOT / f).read_text())
        meta["q"] = int(m.group(1)) if m else None
    # events: every rise of a one-bit signal and every change of the state
    # register, in cycle order; the page captions them
    events = []
    st = meta.get("states", {}).get("signal")
    for k, s in win.items():
        for c, v in s["v"][1:]:
            if s["w"] == 1 and v == "1":
                events.append({"c": c, "k": "rise", "sig": k})
            elif k == st:
                events.append({"c": c, "k": "state", "sig": k, "v": v})
    events.sort(key=lambda e: (e["c"], e["sig"]))
    srcs = sorted(set(re.findall(r"(?<![\w/.-])((?:engines|mem|sec|dbg|sys|common|isa|mom)/[\w/.-]+\.(?:sv|v|py))", log)))
    passed = [l for l in log.splitlines() if l.startswith(("PASS", "pass"))][-1:] or ["(runsim.sh accepted the run)"]
    return {
        "id": t["id"], "label": "Recorded RTL Trace", "title": t["title"], "view": t.get("view", "regs"),
        "test": f"make {t['make']} ({t['tb']})", "result": passed[0][:160],
        "command": f"make {t['make']}", "repo_commit": git_head(ROOT), "tile_commit": "",
        "tools": tool_versions(), "timescale": ts, "clock_ns": (edges[1] - edges[0]) * timescale_ns(ts),
        "cycles": b - a + 1, "window_from_cycle": a,
        "sources": {s: sha(ROOT / s) for s in srcs if (ROOT / s).exists()},
        "signals": win, "events": events, "enums": {}, "meta": meta,
    }


def main():
    import yaml
    spec = yaml.safe_load(SPEC.read_text())
    only = set(sys.argv[1:])
    OUTD.mkdir(parents=True, exist_ok=True)
    for t in spec.get("traces", []):
        if only and t["id"] not in only:
            continue
        if t["runner"] == "tile-rtl":
            rec = record_tile(t)
        elif t["runner"] == "make":
            rec = record_make(t)
        else:
            raise SystemExit(f"atlas_traces: unknown runner {t['runner']}")
        f = OUTD / f"{t['id']}.json"
        f.write_text(json.dumps(rec, separators=(",", ":"), sort_keys=True) + "\n")
        print(f"  {t['id']:14s} {rec['label']}: {rec['cycles']} cycles, {len(rec['events'])} events, "
              f"{f.stat().st_size // 1024} KiB")


if __name__ == "__main__":
    main()
