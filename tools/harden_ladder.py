#!/usr/bin/env python3
"""harden_ladder.py -- harden the tile, unattended, until one configuration
signs off.

    cd ~/src/hydra-skywater130 && python3 tools/harden_ladder.py [hardening checkout]

Each RUNG is one configuration. For each rung, in order, it:

  1. copies the verified tile into the hardening checkout (scripts/sync-tile.sh)
  2. applies that rung's settings to the CHECKOUT's src/config.json only
     (the verified tile in tt/tile is never edited)
  3. runs ./tt/tt_tool.py --create-user-config and tools/tile_size_check.py
  4. runs ./tt/tt_tool.py --harden, watching runs/wokwi; if no file there
     changes for --stall minutes (default 60), the harden is stopped
  5. accepts the rung only if the flow finished AND design rules, layout
     versus schematic, antenna, setup and hold are all clean

The first rung that is accepted is kept in runs/wokwi; the script then runs
the gate-level tests, the slew report and the timing summary on it. A rung
that fails keeps its logs (runs/ladder-<rung>-<time>/, step logs only) and
the next rung starts. Everything is written to
build/harden-ladder/<time>/ladder.log, copied to Windows Downloads when that
folder exists (WSL), so the whole result can be attached in one file.

WHY (2026-10-14..17): with DESIGN_REPAIR_MAX_SLEW_PCT 50, the post-placement
repair step took hours on v3.2 and then never finished on v3.3 (no log
output for over a day, stuck at net 7000 of 11823). A person watching a log
for a day is the wrong tool; a timeout and a fallback are the right one.

Options:
  --stall MIN      minutes without any change under runs/wokwi before a rung
                   is stopped (default 60)
  --rungs a,b      run only these rungs, in this order
  --list           print the rungs and exit
  --stop-current   stop a harden that is already running before starting
"""
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Each rung: name, what it is for, settings to set (None removes the key).
# Tried and rejected, kept here so nobody runs them again:
#   drive2 (v3.5, 2026-10-17): also exclude buf_1 and clkbuf_1. The resizer
#     took dlygate4sd3_1 for every fanout buffer instead; slew 3,298, cap 8,
#     but setup -2.403 ns at max_ss_100C_1v60. Rejected by this ladder.
RUNGS = [
    ("realbuf2",
     "v3.6: no weak or delay buffers at all (buf_1, clkbuf_1, delay gates, delay buffers), so repair can only pick a _2 or stronger real buffer",
     {"DESIGN_REPAIR_MAX_SLEW_PCT": 20, "DESIGN_REPAIR_MAX_CAP_PCT": 20,
      "EXTRA_EXCLUDED_CELLS": ["sky130_fd_sc_hd__clkdlybuf4s*", "sky130_fd_sc_hd__dlygate4sd*",
                               "sky130_fd_sc_hd__dlymetal6s*", "sky130_fd_sc_hd__buf_1",
                               "sky130_fd_sc_hd__clkbuf_1"]}),
    ("buffers20",
     "v3.4, signed off 2026-10-17: real buffers, no delay cells, default 20% repair margins (4,197 slew warnings)",
     {"DESIGN_REPAIR_MAX_SLEW_PCT": 20, "DESIGN_REPAIR_MAX_CAP_PCT": 20,
      "EXTRA_EXCLUDED_CELLS": ["sky130_fd_sc_hd__clkdlybuf4s*"]}),
    ("proven20",
     "the repair settings of every harden before v3.2 (about 5,000 slew warnings, which do not block sign-off)",
     {"DESIGN_REPAIR_MAX_SLEW_PCT": 20, "DESIGN_REPAIR_MAX_CAP_PCT": 20,
      "EXTRA_EXCLUDED_CELLS": None}),
]

TT_HARDEN = os.environ.get("HARDEN_LADDER_TT", "./tt/tt_tool.py")  # tests replace this


class Log:
    def __init__(self, path):
        self.f = open(path, "a", buffering=1)

    def __call__(self, msg=""):
        line = f"{time.strftime('%H:%M:%S')}  {msg}"
        print(line, flush=True)
        self.f.write(line + "\n")


def patch_config(path, settings):
    """Set or remove top-level keys in a LibreLane config.json written with
    repeated "//" comment keys, which json.load would silently collapse.
    Works on lines, then checks the result parses."""
    lines = path.read_text().splitlines()
    for key, value in settings.items():
        rx = re.compile(r'^\s*"' + re.escape(key) + r'"\s*:')
        lines = [l for l in lines if not rx.match(l)]
        if value is not None:
            close = max(i for i, l in enumerate(lines) if l.strip() == "}")
            prev = max(i for i in range(close) if lines[i].strip())
            if not lines[prev].rstrip().endswith((",", "{")):
                lines[prev] = lines[prev].rstrip() + ","
            lines.insert(close, f'  "{key}": {json.dumps(value)}')
    # a key removed from the end can leave a trailing comma before "}"
    close = max(i for i, l in enumerate(lines) if l.strip() == "}")
    prev = max(i for i in range(close) if lines[i].strip())
    lines[prev] = lines[prev].rstrip().rstrip(",")
    text = "\n".join(lines) + "\n"
    cfg = json.loads(text)
    for key, value in settings.items():
        assert cfg.get(key) == value, (key, cfg.get(key), value)
    path.write_text(text)


def newest_change(d):
    newest = 0.0
    for p in d.rglob("*"):
        try:
            newest = max(newest, p.stat().st_mtime)
        except OSError:
            pass
    return newest


def harden_running():
    out = []
    r = subprocess.run(["pgrep", "-x", "openroad"], capture_output=True, text=True)
    out += r.stdout.split()
    if shutil.which("docker"):
        r = subprocess.run(["docker", "ps", "--format", "{{.ID}} {{.Image}}"],
                           capture_output=True, text=True)
        out += [l.split()[0] for l in r.stdout.splitlines() if "librelane" in l]
    return out


def stop_harden(proc, log):
    if proc is not None and proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        for _ in range(30):
            if proc.poll() is not None:
                break
            time.sleep(1)
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
    if shutil.which("docker"):
        r = subprocess.run(["docker", "ps", "--format", "{{.ID}} {{.Image}}"],
                           capture_output=True, text=True)
        for l in r.stdout.splitlines():
            if "librelane" in l:
                log(f"  stopping container {l}")
                subprocess.run(["docker", "kill", l.split()[0]], capture_output=True)
    subprocess.run(["pkill", "-x", "openroad"], capture_output=True)


def judge(hc):
    """(ok, summary) from runs/wokwi/final/metrics.json."""
    f = hc / "runs/wokwi/final/metrics.json"
    if not f.exists():
        return False, "no final/metrics.json: the flow did not finish"
    m = json.loads(f.read_text())

    def g(k, default=None):
        return m.get(k, default)
    checks = {
        "route DRC": g("route__drc_errors"),
        "Magic DRC": g("magic__drc_error__count"),
        "LVS": g("design__lvs_error__count"),
        "antenna nets": g("antenna__violating__nets"),
        "setup ws": g("timing__setup__ws"),
        "hold ws": g("timing__hold__ws"),
    }
    bad = []
    for k in ("route DRC", "Magic DRC", "LVS", "antenna nets"):
        if checks[k] is None or checks[k] != 0:
            bad.append(f"{k}={checks[k]}")
    for k in ("setup ws", "hold ws"):
        if checks[k] is None or checks[k] < 0:
            bad.append(f"{k}={checks[k]}")
    summary = ", ".join(f"{k} {v}" for k, v in checks.items())
    summary += (f", utilisation {g('design__instance__utilization')}"
                f", slew {g('design__max_slew_violation__count')}"
                f", cap {g('design__max_cap_violation__count')}")
    return (not bad), (summary if not bad else "FAILED " + "; ".join(bad) + " | " + summary)


INFRA = [
    (r"Temporary failure in name resolution|Name or service not known|ConnectError|ReadTimeout|ConnectTimeout",
     "a network error while LibreLane was downloading (usually the PDK). Check `getent hosts github.com`; "
     "under WSL, `wsl --shutdown` from PowerShell often fixes name resolution. Then put the PDK somewhere "
     "that survives a restart (PDK_ROOT=$HOME/.ciel, not /tmp)"),
    (r"Cannot connect to the Docker daemon|docker: command not found|permission denied while trying to connect to the Docker",
     "Docker is not reachable. Start Docker Desktop and check `docker ps`"),
    (r"No module named librelane",
     "LibreLane is not installed in this Python. Run: source ~/ttsetup/venv/bin/activate"),
]


def infra_failure(path):
    """A reason string if the harden log shows the machine failed (network,
    Docker, Python) rather than the design; None otherwise."""
    try:
        text = path.read_text(errors="replace")[-200000:]
    except OSError:
        return None
    for rx, why in INFRA:
        if re.search(rx, text):
            return why
    return None


def pdk_warning():
    root = os.environ.get("PDK_ROOT", "")
    if not root:
        return "PDK_ROOT is not set; LibreLane will pick its own location"
    if root.startswith("/tmp"):
        return (f"PDK_ROOT={root} is under /tmp, which WSL empties on restart, so the PDK is "
                "downloaded again (about 1 GB) and a network failure stops the harden. "
                "Prefer PDK_ROOT=$HOME/.ciel")
    return None


def keep_logs(hc, name, stamp, log):
    run = hc / "runs/wokwi"
    if not run.exists():
        return
    dst = hc / f"runs/ladder-{name}-{stamp}"
    dst.mkdir(parents=True, exist_ok=True)
    for p in run.rglob("*.log"):
        q = dst / p.relative_to(run)
        q.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, q)
    shutil.rmtree(run, ignore_errors=True)
    log(f"  logs kept in {dst}; the rest of the run was removed")


def sh(cmd, cwd, log, out):
    log(f"  $ {cmd}")
    r = subprocess.run(cmd, shell=True, cwd=cwd, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    out.write(r.stdout)
    for line in r.stdout.splitlines()[-12:]:
        log(f"    {line}")
    return r.returncode


def selftest():
    import tempfile
    src = (ROOT / "tt/tile/src/config.json").read_text()
    with tempfile.TemporaryDirectory() as d:
        f = pathlib.Path(d) / "config.json"
        f.write_text(src)
        n_comments = src.count('"//"')
        for _, _, settings in RUNGS:
            patch_config(f, settings)
            cfg = json.loads(f.read_text())
            for k, v in settings.items():
                assert cfg.get(k) == v, (k, cfg.get(k), v)
            assert f.read_text().count('"//"') == n_comments, "comments lost"
        patch_config(f, {"EXTRA_EXCLUDED_CELLS": None, "MAGIC_WRITE_LEF_PINONLY": None})
        json.loads(f.read_text())
    with tempfile.TemporaryDirectory() as d:
        f = pathlib.Path(d) / "h.log"
        f.write_text("httpx.ConnectError: [Errno -3] Temporary failure in name resolution\n")
        assert infra_failure(f) and "network" in infra_failure(f)
        f.write_text("[INFO DRT-0199]   Number of violations = 12.\n")
        assert infra_failure(f) is None
    ok, msg = judge(pathlib.Path("/nonexistent"))
    assert not ok and "did not finish" in msg
    print(f"PASS harden_ladder selftest: {len(RUNGS)} rungs patch config.json without losing its comments; machine failures are told apart from design failures")


def main():
    args = sys.argv[1:]
    if "--selftest" in args:
        selftest()
        return 0
    if "--list" in args:
        for n, why, s in RUNGS:
            print(f"{n:10s} {why}\n           {json.dumps(s)}")
        return 0
    stall = 60
    if "--stall" in args:
        stall = float(args[args.index("--stall") + 1])
    order = [r[0] for r in RUNGS]
    if "--rungs" in args:
        order = args[args.index("--rungs") + 1].split(",")
    rungs = [r for n in order for r in RUNGS if r[0] == n]
    if len(rungs) != len(order):
        sys.exit(f"harden_ladder: unknown rung in {order}; --list shows them")
    skip = {"--stall", "--rungs"}
    pos = [a for i, a in enumerate(args)
           if not a.startswith("--") and (i == 0 or args[i - 1] not in skip)]
    hc = pathlib.Path(pos[0] if pos else pathlib.Path.home() / "src/tinytapeout-hydra").resolve()

    # A refused start must not create a log folder: the newest folder is the
    # one people tail, and it should stay the run that is actually going.
    running = harden_running()
    if running and "--stop-current" not in args:
        print(f"harden_ladder: a harden is already running ({' '.join(running)}). "
              "Leave it, or pass --stop-current to replace it.")
        return 2
    stamp = time.strftime("%Y%m%d-%H%M%S")
    outdir = ROOT / "build/harden-ladder" / stamp
    outdir.mkdir(parents=True, exist_ok=True)
    log = Log(outdir / "ladder.log")
    log(f"harden_ladder: checkout {hc}; rungs {', '.join(order)}; stall limit {stall:g} min")

    if os.environ.get("HARDEN_LADDER_TT") is None:
        r = subprocess.run([sys.executable, "-c", "import librelane"], capture_output=True)
        if r.returncode != 0:
            log("LibreLane is not importable from this Python. Run: source ~/ttsetup/venv/bin/activate")
            return 2
    w = pdk_warning()
    if w:
        log(f"note: {w}")
    if running:
        log(f"stopping the harden already running ({' '.join(running)})")
        stop_harden(None, log)

    winner = None
    for name, why, settings in rungs:
        log("")
        log(f"=== rung {name}: {why}")
        out = open(outdir / f"{name}.out", "w")
        if sh(f"./scripts/sync-tile.sh {hc}", ROOT, log, out) != 0:
            log("sync-tile failed: the verified tile does not match its sources. Stopping.")
            return 1
        patch_config(hc / "src/config.json", settings)
        log(f"  config: {json.dumps(settings)}")
        if sh(f"{TT_HARDEN} --create-user-config", hc, log, out) != 0:
            log("  --create-user-config failed; next rung")
            continue
        if sh(f"{sys.executable} {ROOT}/tools/tile_size_check.py {hc}", hc, log, out) not in (0,):
            # a mismatch with an OLD run is fine here; the user config is what matters
            if "src/user_config.json is set up for" not in (outdir / f"{name}.out").read_text():
                log("  tile size check failed; next rung")
                continue
        if (hc / "runs/wokwi").exists():
            keep_logs(hc, "previous", stamp, log)
        log(f"  harden started; stopped if nothing under runs/wokwi changes for {stall:g} min")
        t0 = time.time()
        hout = open(outdir / f"{name}.harden.log", "w")
        proc = subprocess.Popen(f"{TT_HARDEN} --harden", shell=True, cwd=hc, stdout=hout,
                                stderr=subprocess.STDOUT, start_new_session=True)
        stalled = False
        last_report = 0.0
        while proc.poll() is None:
            time.sleep(30 if os.environ.get("HARDEN_LADDER_TT") is None else 1)
            run = hc / "runs/wokwi"
            newest = newest_change(run) if run.exists() else t0
            idle = (time.time() - max(newest, t0)) / 60
            if time.time() - last_report > 600:
                steps = sorted(p.name for p in run.iterdir() if p.is_dir()) if run.exists() else []
                log(f"  {(time.time() - t0) / 60:6.1f} min  step {steps[-1] if steps else '-'}  idle {idle:.0f} min")
                last_report = time.time()
            if idle > stall:
                log(f"  STALLED: nothing changed for {idle:.0f} min; stopping this rung")
                stop_harden(proc, log)
                stalled = True
                break
        hout.close()
        infra = infra_failure(outdir / f"{name}.harden.log")
        if infra:
            log(f"  the harden could not start: {infra}")
            log("  This is the machine, not the design, so no other rung is tried.")
            keep_logs(hc, name, stamp, log)
            break
        ok, summary = (False, "stalled") if stalled else judge(hc)
        log(f"  result after {(time.time() - t0) / 60:.0f} min: {summary}")
        if ok:
            winner = name
            break
        keep_logs(hc, name, stamp, log)

    log("")
    if not winner:
        log("=== no rung signed off. Attach this file; the per-rung logs are beside it.")
    else:
        log(f"=== {winner} signed off. Checking it:")
        out = open(outdir / "checks.out", "w")
        sh(f"{sys.executable} {ROOT}/tools/tile_size_check.py {hc}", hc, log, out)
        sh(f"./scripts/tile-gl.sh {hc}", ROOT, log, out)
        sh(f"{sys.executable} tools/slew_report.py {hc}", ROOT, log, out)
        sh(f"{sys.executable} tools/slew_report.py {hc} nom_tt_025C_1v80", ROOT, log, out)
        sh(f"{sys.executable} {ROOT}/tools/timing_report.py --summary", hc, log, out)
        settings = next(s for n, _, s in RUNGS if n == winner)
        (outdir / "winner.json").write_text(json.dumps({"rung": winner, "settings": settings}, indent=1))
    win = pathlib.Path("/mnt/c/Users/aleks/Downloads")
    if win.is_dir():
        dst = win / f"hydra-harden-ladder-{stamp}.log"
        text = (outdir / "ladder.log").read_text()
        if (outdir / "checks.out").exists():
            text += "\n\n===== full output of the checks =====\n" + (outdir / "checks.out").read_text()
        dst.write_text(text)
        log(f"copied to {dst}")
    return 0 if winner else 1


if __name__ == "__main__":
    sys.exit(main())
