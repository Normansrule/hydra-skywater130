#!/usr/bin/env python3
"""
gen_site.py -- build the project page and the architecture diagram FROM THE
REPOSITORY, so neither can drift away from the hardware.

Two rules make this worth having rather than a hand-drawn picture:

  1. Every block in a diagram names a file AND a module, and the "as built"
     views are checked against a named build: each module must be
     instantiated somewhere in that build's own source list, or the
     generator refuses to draw it (SkyWater 130 audit, 2026-10-11: file
     existence alone said nothing about what is connected). Blocks that
     exist but are in no build are shown separately, as a library, and
     planned work as a roadmap, never as part of a current picture.

  2. Every number comes from docs/metrics.json, with its measurement method
     attached. A figure typed into HTML by hand goes stale the first time
     something is rebuilt, and this project has already been bitten by
     quietly comparing a yosys estimate with a LibreLane result.

The page is a single self-contained file: no content delivery network, no
fonts to fetch, no build step, nothing to install. It opens from disk and it
will still open in ten years.

    make site         regenerate docs/site/index.html and docs/ARCHITECTURE.md
    make site-check   fail if either is out of date with the repository
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "docs/site/index.html"
ARCH = ROOT / "docs/ARCHITECTURE.md"

# ---------------------------------------------------------------------------
# AS BUILT. One named build, its blocks and the connections between them. Each
# block names (file, module); check_built() requires the module to be
# instantiated in the build's own sources. host is software, outside the
# check, and says so.
# ---------------------------------------------------------------------------
AS_BUILT = {
    "name": "ecp5-evn-mem",
    "plan": "plans/ecp5-evn-mem.yaml",
    "title": "As built: ecp5-evn-mem (scheduler + memory-fed array)",
    "blocks": [
        # id,      label,          sub,                         file,                                   module,                 col, row
        ("host",   "Host",         "PC, Python driver",          "tools/hydra_host.py",                  None,                   0, 1),
        ("bridge", "Bridge",       "UART to pins, memory",       "fpga/rtl/hydra_fpga_bridge.sv",        "hydra_fpga_bridge",    1, 1),
        ("spi",    "SPI slave",    "register map",               "mom/rtl/hydra_tt_spi.sv",              "hydra_tt_spi",         2, 0),
        ("regs",   "Registers",    "the host map",               "mom/rtl/hydra_tt_regs.sv",             "hydra_tt_regs",        2, 1),
        ("feat",   "Features",     "log2 work, intensity",       "mom/rtl/mom_features.sv",              "mom_features",         3, 0),
        ("cost",   "Cost engine",  "one, walked over five",      "mom/rtl/mom_cost_engine.sv",           "mom_cost_engine",      3, 1),
        ("sel",    "Select",       "argmin with margin",         "mom/rtl/mom_select.sv",                "mom_select",           4, 1),
        ("sb",     "Scoreboard",   "tags, queue depth",          "mom/rtl/mom_scoreboard.sv",            "mom_scoreboard",       4, 0),
        ("cal",    "Calibrate",    "measured vs predicted",      "mom/rtl/mom_calibrate.sv",             "mom_calibrate",        3, 2),
        ("xbar",   "Crossbar",     "descriptor to engine",       "common/rtl/mom_xbar.sv",               "mom_xbar",             5, 1),
        ("tpu",    "TPU, from memory", "4x4 INT8 array",         "sys/rtl/hydra_engine_tpu_dma.sv",      "hydra_engine_tpu_dma", 6, 0),
        ("models", "Latency models", "CPU, SIMD, NTT, crypto",   "sys/rtl/hydra_sys_tile.sv",            "hydra_sys_tile",       6, 2),
        ("dma",    "Streamer",     "banks to the array",         "mem/rtl/hydra_dma_gemm.sv",            "hydra_dma_gemm",       7, 0),
        ("bank",   "Scratchpad",   "A, B, results",              "mem/rtl/hydra_spram.sv",               "hydra_spram",          7, 1),
    ],
    "edges": [
        # (from, to, label[, via row]): an edge with a via row is drawn
        # orthogonally along that empty row instead of through other blocks.
        ("host", "bridge", "bytes"), ("bridge", "spi", "pins"), ("bridge", "bank", "load, read", 3),
        ("spi", "regs", ""), ("regs", "feat", "descriptor"), ("feat", "cost", ""),
        ("cost", "sel", "5 costs"), ("sb", "cost", "queue"), ("sel", "xbar", "engine"),
        ("xbar", "sb", "tag, done"), ("xbar", "tpu", "job"), ("xbar", "models", "job"),
        ("bank", "dma", ""), ("dma", "tpu", "operands"),
        ("sb", "cal", ""), ("cal", "cost", "k"),
    ],
}

# The Tiny Tapeout tile: the scheduler and nothing else.
TILE_BUILT = {
    "name": "tt_um_hydra_mom",
    "sources_dir": "tt/tile/src",
    "title": "As built: the Tiny Tapeout tile (scheduler only)",
    "blocks": [
        ("pins",   "Pins",         "SPI on ui/uo",               "tt/tile/src/tt_um_hydra_mom.sv",       None,                   0, 2),
        ("spi",    "SPI slave",    "mode 0",                     "tt/tile/src/rtl/hydra_tt_spi.sv",      "hydra_tt_spi",         1, 2),
        ("regs",   "Registers",    "the host map",               "tt/tile/src/rtl/hydra_tt_regs.sv",     "hydra_tt_regs",        2, 2),
        ("feat",   "Features",     "log2 work, intensity",       "tt/tile/src/rtl/mom_features.sv",      "mom_features",         3, 1),
        ("cost",   "Cost engine",  "one, walked over five",      "tt/tile/src/rtl/mom_cost_engine.sv",   "mom_cost_engine",      3, 2),
        ("sel",    "Select",       "argmin with margin",         "tt/tile/src/rtl/mom_select.sv",        "mom_select",           4, 2),
        ("sb",     "Scoreboard",   "4 tags",                     "tt/tile/src/rtl/mom_scoreboard.sv",    "mom_scoreboard",       4, 1),
        ("cal",    "Calibrate",    "host-reported completions",  "tt/tile/src/rtl/mom_calibrate.sv",     "mom_calibrate",        3, 3),
    ],
    "edges": [
        ("pins", "spi", ""), ("spi", "regs", ""), ("regs", "feat", "descriptor"),
        ("feat", "cost", ""), ("cost", "sel", "5 costs"), ("sb", "cost", "queue"),
        ("sel", "regs", "decision", 4), ("regs", "sb", "COMP", 0), ("sb", "cal", ""),
        ("cal", "cost", "k"),
    ],
}

# IP LIBRARY. Blocks that exist and have their own checks, whether or not any
# build connects them. Listed, not wired: no edges are drawn between them.
LIBRARY = [
    # label,           what,                               file,                                  make target
    ("TPU array",      "4x4 INT8 systolic array",          "engines/tpu/rtl/tpu_top.sv",          "tpu"),
    ("Vector unit",    "4 x 32-bit lanes (not a GPU)",     "engines/simd/rtl/simd_top.sv",        "simd"),
    ("NTT",            "4 Barrett butterflies, 3 moduli",  "engines/ntt/rtl/ntt_top.sv",          "ntt-moduli"),
    ("Vector unit, from memory", "streamer and banks",     "sys/rtl/hydra_engine_simd_dma.sv",    "dma-simd"),
    ("NTT, from memory", "memory format v1",               "sys/rtl/hydra_engine_ntt_dma.sv",     "dma-ntt"),
    ("Test port",      "IEEE 1149.1 TAP, own clock",       "dbg/rtl/hydra_jtag_tap.sv",           "jtag"),
    ("Clock crossing", "test port into the register map",  "dbg/rtl/hydra_jtag_bridge.sv",        "jtag-bridge"),
    ("Key vault",      "write and use, never read back",   "sec/rtl/hydra_key_vault.sv",          "keyvault"),
    ("Mailbox",        "lock, command, execute",           "sec/rtl/hydra_mailbox.sv",            "mailbox"),
    ("SHA-256",        "padded in hardware",               "sec/rtl/hydra_sha256_stream.sv",      "sha256-stream"),
    ("Measurement",    "extend-only register",             "sec/rtl/hydra_pcr.sv",                "pcr"),
    ("Security ISA",   "Zknh + Xhydrasec unit",            "isa/rtl/hydra_xsec_unit.sv",          "xsec"),
    ("Pad multiplexer", "OpenFrame pad ownership",         "common/rtl/hydra_padmux.sv",          "padmux"),
]

# ROADMAP. Not built. Each names the document that specifies it.
ROADMAP = [
    ("CPU",            "Sixfold RV64, needs a program-load port",  "docs/architecture/heterogeneous-system.md"),
    ("GPU",            "Pixelstorm SIMT, sixth dispatch slot",     "docs/architecture/heterogeneous-system.md"),
    ("FHE profile",    "BFV via pinned OpenFHE, leveled",          "docs/security/fhe-profile.md"),
    ("SE boundary",    "authenticated, zeroised, access-checked",  "docs/security/se-contract.md"),
    ("Mode transition", "QUIESCE, DRAIN, ZEROIZE, INSTALL",        "docs/security/mode-transition.md"),
]

COLW, ROWH, BW, BH = 196, 104, 132, 58
PAD_X, PAD_Y = 40, 40


# Each engine the page claims must have RTL on disk and a Makefile target
# that checks it. A page can advertise an engine that was deleted, or one
# whose bench was quietly dropped from the suite; neither should survive a
# regeneration.
ENGINE_EVIDENCE = {
    "TPU":      ("engines/tpu/rtl",  "tpu:"),
    "SIMD":     ("engines/simd/rtl", "simd:"),
    "NTT":      ("engines/ntt/rtl",  "ntt:"),
    "Streamer": ("mem/rtl",          "dma:"),
    "JTAG":     ("dbg/rtl",          "jtag:"),
    "SHA-256":  ("sec/rtl",          "sha256:"),
    "Measurement": ("sec/rtl",       "measure:"),
}

# Each board the page lists must have a plan the build can read.
BOARD_PLANS = "plans/{plan}.yaml"


def _sources(build):
    """The build's own source list: the plan's, or every .sv under the tile."""
    if "plan" in build:
        import yaml
        plan = yaml.safe_load((ROOT / build["plan"]).read_text())
        return [ROOT / f for f in plan["sources"]]
    return sorted((ROOT / build["sources_dir"]).rglob("*.sv"))


def instantiated(module, sources):
    """True if some source file instantiates `module` (not merely defines it)."""
    import re
    pat = re.compile(r"(?m)^\s*" + re.escape(module) + r"\s*(#\s*\(|[A-Za-z_]\w*\s*\()")
    return any(pat.search(f.read_text()) for f in sources)


def check_built(build):
    problems = []
    srcs = _sources(build)
    for bid, label, _, f, mod, _, _ in build["blocks"]:
        if not (ROOT / f).exists():
            problems.append(f"{build['name']}: block '{label}' names a missing file: {f}")
        elif mod is not None and not instantiated(mod, srcs):
            problems.append(f"{build['name']}: block '{label}' ({mod}) is not instantiated in that build")
    ids = {b[0] for b in build["blocks"]}
    for e in build["edges"]:
        a, b = e[0], e[1]
        if a not in ids or b not in ids:
            problems.append(f"{build['name']}: edge {a} -> {b} names a block not in the build")
    return problems


def check_files():
    """Refuse to publish claims the repository does not back up."""
    problems = check_built(AS_BUILT) + check_built(TILE_BUILT)
    makefile = (ROOT / "Makefile").read_text()

    for label, _, f, target in LIBRARY:
        if not (ROOT / f).exists():
            problems.append(f"library block '{label}' names a missing file: {f}")
        if f"\n{target}:" not in makefile:
            problems.append(f"library block '{label}' has no '{target}' target")
    for label, _, doc in ROADMAP:
        if not (ROOT / doc).exists():
            problems.append(f"roadmap item '{label}' names a missing specification: {doc}")

    m = json.loads((ROOT / "docs/metrics.json").read_text())
    for e in m["engines"]:
        rtl, target = ENGINE_EVIDENCE.get(e["name"], (None, None))
        if rtl is None:
            problems.append(f"engine '{e['name']}' has no evidence rule here")
            continue
        if not (ROOT / rtl).is_dir():
            problems.append(f"engine '{e['name']}' claims {rtl}, which is absent")
        if target not in makefile:
            problems.append(
                f"engine '{e['name']}' has no '{target}' target: the page would"
                f" advertise hardware nothing in the suite checks")
    for v in m["verification"]:
        t = v.get("target")
        if not t or f"\n{t}:" not in makefile:
            problems.append(f"verification '{v['what']}' names no make target that exists ({t!r})")

    for b in m["boards"]:
        plan = ROOT / BOARD_PLANS.format(plan=b["plan"])
        if not plan.exists():
            problems.append(f"board '{b['plan']}' has no plan at {plan.relative_to(ROOT)}")

    if problems:
        print("gen_site: refusing to generate --")
        for p in problems:
            print(f"  {p}")
        sys.exit(1)


def pos(col, row):
    return PAD_X + col * COLW, PAD_Y + row * ROWH


def svg_graph(build):
    blocks, edges = build["blocks"], build["edges"]
    rows = [b[6] for b in blocks] + [e[3] for e in edges if len(e) > 3]
    w = PAD_X * 2 + (max(b[5] for b in blocks)) * COLW + BW
    h = PAD_Y * 2 + max(rows) * ROWH + BH
    at = {b[0]: pos(b[5], b[6]) for b in blocks}

    out = [f'<svg class="diagram" viewBox="0 0 {w} {h}" '
           f'xmlns="http://www.w3.org/2000/svg" role="img" '
           f'aria-label="{build["title"]}. The same blocks and connections are listed as text below the figure.">',
           '<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" '
           'markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
           '<path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor"/></marker></defs>']

    for e in edges:
        a, b, label = e[:3]
        ax, ay = at[a]
        bx, by = at[b]
        x1, y1 = ax + BW / 2, ay + BH / 2
        x2, y2 = bx + BW / 2, by + BH / 2
        mx = (x1 + x2) / 2
        if len(e) > 3:
            # orthogonal, along an empty row: leave and enter through the
            # box edge that faces that row
            yv = PAD_Y + e[3] * ROWH + BH / 2
            ys = ay + BH if yv > ay else ay
            ye = by + BH if yv > by else by
            path = f"M {x1} {ys} V {yv} H {x2} V {ye}"
            ly = yv - 6
        else:
            path = f"M {x1} {y1} C {mx} {y1}, {mx} {y2}, {x2} {y2}"
            ly = (y1 + y2) / 2 - 6
        out.append(f'<path class="edge" data-a="{a}" data-b="{b}" d="{path}" '
                   f'marker-end="url(#ah)"/>')
        if label:
            out.append(f'<text class="edge-label" x="{mx}" y="{ly}">{label}</text>')

    for bid, label, sub, path, _, col, row in blocks:
        x, y = pos(col, row)
        out.append(
            f'<g class="node" data-id="{bid}" tabindex="0">'
            f'<title>{path}</title>'
            f'<rect x="{x}" y="{y}" width="{BW}" height="{BH}" rx="9"/>'
            f'<text class="n-label" x="{x + BW/2}" y="{y + 24}">{label}</text>'
            f'<text class="n-sub" x="{x + BW/2}" y="{y + 42}">{sub}</text>'
            f'</g>')
    out.append("</svg>")
    return "\n".join(out)


def svg_diagram():
    """The README's architecture figure: the as-built memory image."""
    return svg_graph(AS_BUILT)


def text_alt(build):
    """The figure as text: every block with its file, every connection."""
    names = {b[0]: b[1] for b in build["blocks"]}
    rows = "".join(f"<li><b>{label}</b> ({sub}) — <code>{f}</code></li>"
                   for _, label, sub, f, _, _, _ in build["blocks"])
    conns = "".join(f"<li>{names[e[0]]} → {names[e[1]]}{': ' + e[2] if e[2] else ''}</li>"
                    for e in build["edges"])
    return (f"<details><summary>{build['title']}, as text</summary>"
            f"<h3>Blocks</h3><ul>{rows}</ul><h3>Connections</h3><ul>{conns}</ul></details>")


def mermaid(build, dashed=False):
    lines = ["flowchart LR"]
    for bid, label, sub, path, _, _, _ in build["blocks"]:
        lines.append(f'  {bid}["{label}<br/><small>{sub}</small>"]')
    for e in build["edges"]:
        a, b, label = e[:3]
        arrow = (f"-. {label} .->" if label else "-.->") if dashed else (f"-- {label} -->" if label else "-->")
        lines.append(f"  {a} {arrow} {b}")
    return "\n".join(lines)


def proof_tasks():
    """Proof and cover tasks that `make verify` actually runs, read from the
    Makefile: the verify prerequisites, their recipes, and every `sby -f
    <file> <task>` in them. Counting .sby files (the old rule) counted
    configurations, some with several tasks and some covers, not proofs."""
    import re
    mk = (ROOT / "Makefile").read_text()
    verify = re.search(r"(?m)^verify:([^\n]*)", mk).group(1).split()
    recipes, cur = {}, None
    for line in mk.splitlines():
        m = re.match(r"^([A-Za-z0-9_.-]+):", line)
        if m:
            cur = m.group(1); recipes.setdefault(cur, [])
        elif line.startswith("\t") and cur:
            recipes[cur].append(line)
    tasks = set()
    for t in verify:
        for line in recipes.get(t, []):
            for f, task in re.findall(r"sby -f (\S+\.sby) (\w+)", line):
                tasks.add((f, task))
    proofs = sorted(x for x in tasks if x[1] != "cover")
    covers = sorted(x for x in tasks if x[1] == "cover")
    return proofs, covers


def svg_area(m):
    """Where the tile's silicon actually goes, to scale.

    A table of areas is read; a picture of areas is UNDERSTOOD. The point
    this makes in one glance is the one that drove the whole redesign: the
    cost engines were the biggest thing on the tile.
    """
    rows = [(e["name"], e["um2"]) for e in m["engines"] if e["um2"]]
    rows.sort(key=lambda r: -r[1])
    total = sum(r[1] for r in rows)
    w, h, y = 900, 58, 0
    out = [f'<svg class="bars" viewBox="0 0 {w} {len(rows)*h + 10}" '
           f'xmlns="http://www.w3.org/2000/svg" role="img" '
           f'aria-label="Standard cell area by block">']
    for name, a in rows:
        bw = max(6, int((w - 250) * a / total))
        out.append(
            f'<g class="bar"><rect x="150" y="{y+12}" width="{bw}" height="26" rx="4"/>'
            f'<text class="b-name" x="140" y="{y+30}">{name}</text>'
            f'<text class="b-val" x="{150+bw+10}" y="{y+30}">{a:,} µm²</text></g>')
        y += h
    out.append("</svg>")
    return "\n".join(out)


def svg_sweep():
    """How one cost engine covers five, in time.

    The change that made the tile 26% smaller is a trade of area for cycles,
    and the two-cycles-per-engine detail is the part people get wrong when
    they reimplement it. Drawn, the reason is obvious: the engine's second
    stage needs its inputs still standing.
    """
    cell, x0, y0 = 62, 120, 34
    out = [f'<svg class="sweep" viewBox="0 0 {x0 + cell*11 + 40} 200" '
           f'xmlns="http://www.w3.org/2000/svg" role="img" '
           f'aria-label="One cost engine walked over five parameter rows">']
    out.append(f'<text class="s-lab" x="10" y="{y0+18}">cycle</text>')
    for c in range(10):
        out.append(f'<text class="s-num" x="{x0 + c*cell + cell/2}" y="{y0+18}">{c}</text>')
    out.append(f'<text class="s-lab" x="10" y="{y0+62}">engine</text>')
    for e in range(5):
        x = x0 + e*2*cell
        out.append(
            f'<rect class="s-eng" x="{x+3}" y="{y0+40}" width="{2*cell-6}" height="34" rx="5"/>'
            f'<text class="s-num" x="{x+cell}" y="{y0+62}">{e}</text>')
    out.append(f'<text class="s-lab" x="10" y="{y0+106}">phase</text>')
    for c in range(10):
        x = x0 + c*cell
        lab = "latch" if c % 2 == 0 else "capture"
        cls = "s-a" if c % 2 == 0 else "s-b"
        out.append(f'<rect class="{cls}" x="{x+3}" y="{y0+84}" width="{cell-6}" height="30" rx="5"/>'
                   f'<text class="s-ph" x="{x+cell/2}" y="{y0+104}">{lab}</text>')
    out.append(f'<text class="s-note" x="{x0}" y="{y0+142}">'
               f'Two cycles each: the engine\u2019s second stage consumes the calibration '
               f'factor, an input, so each engine\u2019s inputs are held across both.</text>')
    out.append("</svg>")
    return "\n".join(out)


def svg_verify(m):
    """What kind of evidence backs each claim.

    "Tested" covers everything from one happy path to an exhaustive proof.
    Splitting the checks by KIND is the honest summary: it shows at a glance
    how much rests on sampling and how much on proof.
    """
    kinds = {}
    for v in m["verification"]:
        kinds.setdefault(v["kind"], []).append(v["what"])
    out = ['<div class="kinds">']
    for k, items in sorted(kinds.items(), key=lambda kv: -len(kv[1])):
        out.append(f'<div class="kind-col"><div class="kind-h">{k}'
                   f'<span class="kind-n">{len(items)}</span></div><ul>')
        for i in items:
            out.append(f"<li>{i}</li>")
        out.append("</ul></div>")
    out.append("</div>")
    return "\n".join(out)


def html(m):
    eng_rows = "".join(
        f"<tr><th scope='row'>{e['name']}</th><td>{e['what']}</td>"
        f"<td class='num'>{format(e['cells'], ',') if e['cells'] else '<span class=\"todo\">not measured</span>'}</td>"
        f"<td class='num'>{format(e['um2'], ',') + ' µm²' if e['um2'] else '<span class=\"todo\">not measured</span>'}</td>"
        f"<td>{e['results']}</td><td>{e['mutations']}</td></tr>"
        for e in m["engines"])

    board_rows = "".join(
        f"<tr><th scope='row'>{b['plan']}</th><td>{b['what']}</td>"
        f"<td class='num'>{b['luts']:,}</td><td class='num'>{b['ffs']:,}</td>"
        f"<td class='num'>{b['mult']}</td><td class='num'>{b['fmax']} MHz</td></tr>"
        for b in m["boards"])

    ver_rows = "".join(
        f"<tr><th scope='row'>{v['what']}</th><td class='num'>{v['result']}</td>"
        f"<td><span class='kind'>{v['kind']}</span></td><td><code>make {v['target']}</code></td></tr>"
        for v in m["verification"])

    lib_rows = "".join(
        f"<tr><th scope='row'>{label}</th><td>{what}</td><td><code>{f}</code></td>"
        f"<td><code>make {t}</code></td><td><span class='status st-lib'>LIBRARY</span></td></tr>"
        for label, what, f, t in LIBRARY)

    road_rows = "".join(
        f"<tr><th scope='row'>{label}</th><td>{what}</td><td><code>{doc}</code></td>"
        f"<td><span class='status st-planned'>PLANNED</span></td></tr>"
        for label, what, doc in ROADMAP)

    proofs, covers = proof_tasks()
    pending = "".join(f"<li>{p}</li>" for p in m["pending"])

    t = m["tile"]
    saved = t["parallel_um2"] - t["shared_um2"]
    pct = round(100 * saved / t["parallel_um2"])

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>HYDRA-130 — adaptive scheduling and accelerator research</title>
<style>
  :root {{
    box-sizing: border-box;
    padding-top: env(safe-area-inset-top, 0px);
    padding-bottom: env(safe-area-inset-bottom, 0px);
    --bg: #0d1016; --panel: #151a23; --line: #26303f;
    --ink: #e6edf5; --dim: #8b9bb0; --accent: #5ad1c8; --warn: #e9b45a;
  }}
  *, *::before, *::after {{ box-sizing: inherit; }}
  @media (prefers-color-scheme: light) {{
    :root:not([data-theme="dark"]) {{
      --bg: #f7f9fc; --panel: #ffffff; --line: #d7dee8;
      --ink: #121821; --dim: #5a6a7d; --accent: #0d7d73; --warn: #9a6a12;
    }}
  }}
  :root[data-theme="dark"] {{
    --bg: #0d1016; --panel: #151a23; --line: #26303f;
    --ink: #e6edf5; --dim: #8b9bb0; --accent: #5ad1c8; --warn: #e9b45a;
  }}
  html {{ scroll-padding-top: env(safe-area-inset-top, 0px); }}
  body {{
    margin: 0; background: var(--bg); color: var(--ink);
    font: 16px/1.62 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }}
  .wrap {{ max-width: 1120px; margin: 0 auto; padding: 0 20px 96px; }}
  header {{ padding: 72px 0 28px; border-bottom: 1px solid var(--line); }}
  h1 {{ font-size: clamp(30px, 5vw, 46px); margin: 0 0 8px; letter-spacing: -0.02em; }}
  .tag {{ color: var(--accent); font: 600 13px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
          letter-spacing: 0.14em; text-transform: uppercase; }}
  .lede {{ color: var(--dim); font-size: 19px; max-width: 70ch; margin: 14px 0 0; }}
  h2 {{ font-size: 13px; letter-spacing: 0.14em; text-transform: uppercase;
        color: var(--dim); margin: 56px 0 14px; font-weight: 700; }}
  p {{ max-width: 72ch; }}
  .panel {{ background: var(--panel); border: 1px solid var(--line);
            border-radius: 14px; padding: 18px; overflow-x: auto; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 14.5px; min-width: 620px; }}
  th, td {{ text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--line); }}
  thead th {{ color: var(--dim); font-size: 12px; letter-spacing: .08em;
              text-transform: uppercase; }}
  tbody th {{ font-weight: 650; white-space: nowrap; }}
  tr:last-child td, tr:last-child th {{ border-bottom: 0; }}
  .num {{ font-variant-numeric: tabular-nums;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
  .kind {{ font-size: 12px; color: var(--accent); border: 1px solid var(--line);
           border-radius: 999px; padding: 2px 9px; white-space: nowrap; }}
  .todo {{ color: var(--warn); }}
  .cards {{ display: grid; gap: 14px; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); }}
  .card {{ background: var(--panel); border: 1px solid var(--line);
           border-radius: 14px; padding: 16px 18px; }}
  .card .k {{ font: 700 28px/1.1 ui-monospace, SFMono-Regular, Menlo, monospace;
              color: var(--accent); font-variant-numeric: tabular-nums; }}
  .card .v {{ color: var(--dim); font-size: 13.5px; margin-top: 6px; }}
  .diagram {{ width: 100%; height: auto; color: var(--dim); display: block; min-width: 900px; }}
  .node rect {{ fill: var(--panel); stroke: var(--line); stroke-width: 1.5; transition: .18s; }}
  .node text {{ text-anchor: middle; fill: var(--ink); }}
  .n-label {{ font: 600 14px ui-sans-serif, system-ui, sans-serif; }}
  .n-sub {{ font: 11.5px ui-monospace, SFMono-Regular, Menlo, monospace; fill: var(--dim); }}
  .node:hover rect, .node:focus rect {{ stroke: var(--accent); stroke-width: 2.5; }}
  .edge {{ fill: none; stroke: var(--line); stroke-width: 1.6; }}
  .edge-label {{ font: 10.5px ui-monospace, SFMono-Regular, Menlo, monospace;
                 fill: var(--dim); text-anchor: middle; }}
  .scroll-note {{ color: var(--dim); font-size: 12.5px; margin: 8px 0 0; }}
  .warn {{ border-left: 3px solid var(--warn); padding-left: 16px; }}
  .warn li {{ color: var(--dim); margin: 7px 0; max-width: 72ch; }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13.5px;
          background: var(--panel); border: 1px solid var(--line);
          border-radius: 6px; padding: 1px 6px; }}
  .bars {{ width: 100%; height: auto; min-width: 620px; }}
  .bar rect {{ fill: var(--accent); opacity: .82; transition: opacity .15s; }}
  .bar:hover rect {{ opacity: 1; }}
  .b-name {{ font: 600 13px ui-sans-serif, system-ui, sans-serif; fill: var(--ink); text-anchor: end; }}
  .b-val {{ font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; fill: var(--dim); }}
  .sweep {{ width: 100%; height: auto; min-width: 760px; }}
  .s-eng {{ fill: none; stroke: var(--accent); stroke-width: 1.6; }}
  .s-a {{ fill: var(--accent); opacity: .30; }}
  .s-b {{ fill: var(--accent); opacity: .62; }}
  .s-lab {{ font: 11px ui-monospace, monospace; fill: var(--dim); }}
  .s-num {{ font: 12px ui-monospace, monospace; fill: var(--ink); text-anchor: middle; }}
  .s-ph {{ font: 10px ui-monospace, monospace; fill: var(--ink); text-anchor: middle; }}
  .s-note {{ font: 12px ui-sans-serif, system-ui, sans-serif; fill: var(--dim); }}
  .kinds {{ display: grid; gap: 14px; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); }}
  .kind-col {{ background: var(--panel); border: 1px solid var(--line);
               border-radius: 14px; padding: 14px 16px; }}
  .kind-h {{ font: 600 12px ui-monospace, monospace; letter-spacing: .08em;
             text-transform: uppercase; color: var(--accent);
             display: flex; justify-content: space-between; align-items: center; }}
  .kind-n {{ color: var(--dim); font-size: 15px; }}
  .kind-col ul {{ margin: 10px 0 0; padding-left: 18px; }}
  .kind-col li {{ color: var(--dim); font-size: 13.5px; margin: 5px 0; }}
  footer {{ color: var(--dim); font-size: 13px; margin-top: 64px;
            border-top: 1px solid var(--line); padding-top: 18px; }}
  .skip {{ position: absolute; left: -9999px; top: 8px; background: var(--panel);
           color: var(--ink); padding: 8px 14px; border-radius: 8px; z-index: 9; }}
  .skip:focus {{ left: 12px; }}
  nav.toc {{ display: flex; flex-wrap: wrap; gap: 6px 16px; margin: 18px 0 0; font-size: 14px; }}
  nav.toc a {{ color: var(--accent); }}
  a:focus-visible, .node:focus-visible, summary:focus-visible {{
    outline: 3px solid var(--accent); outline-offset: 3px; border-radius: 4px; }}
  .node:focus-visible rect {{ stroke: var(--accent); stroke-width: 3; }}
  .status {{ display: inline-block; font: 700 11px/1 ui-monospace, monospace; letter-spacing: .08em;
             border: 1px solid currentColor; border-radius: 999px; padding: 3px 8px; }}
  .st-built {{ color: var(--accent); }} .st-planned {{ color: var(--warn); }} .st-lib {{ color: var(--dim); }}
  .callout {{ border-left: 3px solid var(--warn); background: var(--panel); padding: 12px 16px;
              border-radius: 0 10px 10px 0; max-width: 78ch; }}
  details {{ margin-top: 10px; }}
  details h3 {{ font-size: 14px; margin: 12px 0 4px; }}
  details li {{ color: var(--dim); font-size: 13.5px; }}
  @media (max-width: 640px) {{ .wrap {{ padding: 0 16px 64px; }} header {{ padding-top: 40px; }} }}
  @media print {{
    :root {{ --bg: #fff; --panel: #fff; --ink: #000; --dim: #333; --line: #bbb; --accent: #0d5f58; --warn: #7a520c; }}
    .skip, nav.toc {{ display: none; }}
    .panel {{ overflow: visible; break-inside: avoid; }}
    .diagram, .bars, .sweep {{ min-width: 0; }}
    details {{ display: block; }} details > * {{ display: block; }}
    a {{ color: #000; }}
  }}
</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="wrap">

<header>
  <div class="tag">FPGA · SkyWater sky130 · Tiny Tapeout</div>
  <h1>HYDRA-130</h1>
  <p class="lede">Adaptive hardware scheduling and accelerator research. A
  dispatcher predicts how long each engine would take a piece of work, sends
  it to the cheapest, measures what happened and corrects its own model.
  What runs depends on the build: each view below names one.</p>
  <nav class="toc" aria-label="Sections">
    <a href="#built">As built</a><a href="#tile">The tile</a><a href="#library">IP library</a>
    <a href="#roadmap">Roadmap</a><a href="#area">Area</a><a href="#boards">Board images</a>
    <a href="#verify">Verification</a><a href="#pending">Not done</a>
  </nav>
</header>

<main id="main">
<p class="callout"><b>Status.</b> Not a complete or board-qualified CPU/GPU/TPU
system. No image has run on a physical board. No CPU or GPU is integrated, and
fully homomorphic encryption and sequestered execution are specifications,
refused by the host driver. The Tiny Tapeout tile is the scheduler alone. See
<code>docs/verification/capability-matrix.md</code>.</p>

<h2 id="built">{AS_BUILT['title']}</h2>
<div class="panel">
{svg_graph(AS_BUILT)}
</div>
{text_alt(AS_BUILT)}
<p class="scroll-note"><span class="status st-built">AS BUILT</span> Every block
here is instantiated in that build's own source list
(<code>{AS_BUILT['plan']}</code>); the generator checks it and refuses to draw a
block that is not. The CPU, vector, NTT and crypto slots in this build are
latency models. Wide figure: scroll sideways, or read the text version.</p>

<h2 id="tile">{TILE_BUILT['title']}</h2>
<div class="panel">
{svg_graph(TILE_BUILT)}
</div>
{text_alt(TILE_BUILT)}

<h2 id="library">IP library: built and checked, not all connected</h2>
<div class="panel"><table>
<thead><tr><th scope="col">Block</th><th scope="col">What</th><th scope="col">File</th>
<th scope="col">Check</th><th scope="col">Status</th></tr></thead>
<tbody>{lib_rows}</tbody>
</table></div>
<p class="scroll-note">These exist and pass their own checks. Being listed
here says nothing about being wired into a build; the as-built views above
are the only claims of connection.</p>

<h2 id="roadmap">Roadmap: specified, not built</h2>
<div class="panel"><table>
<thead><tr><th scope="col">Item</th><th scope="col">What</th><th scope="col">Specification</th>
<th scope="col">Status</th></tr></thead>
<tbody>{road_rows}</tbody>
</table></div>

<h2 id="area">Where the tile's cells go</h2>
<div class="panel">
{svg_area(m)}
</div>
<p class="scroll-note">Synthesized standard-cell area per block ({t['method']}).
{t['caveat']} An area chart, not a placed floorplan.</p>

<h2>One cost engine doing the work of five</h2>
<div class="panel">
{svg_sweep()}
</div>
<p class="scroll-note">{t['shared_um2']:,} µm² of cells with one shared cost
engine, {pct}% less than {t['parallel_um2']:,} µm² with five (same synthesis
method). The cycle structure is the real one (<code>mom/rtl/mom_top.sv</code>).</p>

<h2>Engines</h2>
<div class="panel"><table>
<thead><tr><th scope="col">Engine</th><th scope="col">What it is</th><th scope="col">Cells</th>
<th scope="col">Area</th><th scope="col">Checked against a model</th><th scope="col">Mutation testing</th></tr></thead>
<tbody>{eng_rows}</tbody>
</table></div>

<h2 id="boards">Board images</h2>
<div class="panel"><table>
<thead><tr><th scope="col">Plan</th><th scope="col">What it carries</th><th scope="col">LUT4</th>
<th scope="col">Flops</th><th scope="col">Multipliers</th><th scope="col">Fmax</th></tr></thead>
<tbody>{board_rows}</tbody>
</table></div>
<p class="scroll-note">nextpnr place-and-route figures as recorded in
<code>docs/metrics.json</code>, from an earlier run whose revision was not
recorded; they predate later RTL changes. Lattice ECP5 evaluation board. None
of these images has been run on a board.</p>

<h2 id="verify">How it is verified</h2>
<div class="panel"><table>
<thead><tr><th scope="col">Check</th><th scope="col">Scale</th><th scope="col">Kind</th>
<th scope="col">Run with</th></tr></thead>
<tbody>{ver_rows}</tbody>
</table></div>
<p><code>make verify</code> runs {len(proofs)} proof tasks and {len(covers)}
cover tasks, read from the Makefile by this generator, and fails if any of
them fails. A proof establishes its named property under its stated
assumptions, nothing wider. Results quoted in the table are from the run
archived in <code>reports/</code>; this page does not run anything.</p>

<h2>What kind of evidence</h2>
{svg_verify(m)}

<h2 id="pending">What has not been done</h2>
<ul class="warn">{pending}</ul>
</main>

<footer>
  Generated by <code>tools/gen_site.py</code> from <code>docs/metrics.json</code>,
  the build plans and the module tree. <code>make site-check</code> regenerates
  it into a scratch directory and fails if the committed page differs.
</footer>

</div>
<script>
  // Highlight a block and the wires touching it. No library, no build step:
  // the page has to open from disk years from now without fetching anything.
  // Everything the script adds is also in the text versions above.
  for (const svg of document.querySelectorAll('svg.diagram')) {{
    const edges = [...svg.querySelectorAll('.edge')];
    for (const n of svg.querySelectorAll('.node')) {{
      const id = n.dataset.id;
      const on = () => edges.forEach(e => {{
        if (e.dataset.a === id || e.dataset.b === id) {{
          e.style.stroke = 'var(--accent)'; e.style.strokeWidth = '2.6';
        }}
      }});
      const off = () => edges.forEach(e => {{ e.style.stroke = ''; e.style.strokeWidth = ''; }});
      n.addEventListener('mouseenter', on);
      n.addEventListener('mouseleave', off);
      n.addEventListener('focus', on);
      n.addEventListener('blur', off);
    }}
  }}
</script>
</body>
</html>
"""


def check_proof_count(m):
    """The page and metrics.json must agree with the Makefile on how many
    proof tasks make verify runs. A hand-kept count drifts the moment a proof
    is added (it said 10 while there were 14 proof files, 2026-10-07), and
    counting .sby files counted configurations, not proofs (SkyWater 130
    audit, 2026-10-11)."""
    proofs, _ = proof_tasks()
    for v in m["verification"]:
        if v["what"] == "formal proof tasks run by make verify" and v["result"] != f"{len(proofs)} tasks":
            raise SystemExit(f"gen_site: metrics.json says '{v['result']}', but make verify runs "
                             f"{len(proofs)} proof tasks -- update docs/metrics.json")


def architecture_md():
    def table(build):
        return "".join(f"| {label} | `{f}` | `{mod or '(software)'}` |\n"
                       for _, label, _, f, mod, _, _ in build["blocks"])
    return (
        "# HYDRA-130 architecture\n\n"
        "Generated by `tools/gen_site.py`; `make site-check` proves it still matches the\n"
        "repository. Three views, kept apart on purpose (SkyWater 130 audit, 2026-10-11):\n"
        "what one named build contains, what exists as checked IP, and what is planned.\n\n"
        f"## {AS_BUILT['title']}\n\n"
        f"Every module below is instantiated in `{AS_BUILT['plan']}`'s own source list; the\n"
        "generator checks it. The CPU, vector, NTT and crypto slots are latency models.\n\n"
        "```mermaid\n" + mermaid(AS_BUILT) + "\n```\n\n"
        "| block | file | module |\n|---|---|---|\n" + table(AS_BUILT) + "\n"
        f"## {TILE_BUILT['title']}\n\n"
        "```mermaid\n" + mermaid(TILE_BUILT) + "\n```\n\n"
        "| block | file | module |\n|---|---|---|\n" + table(TILE_BUILT) + "\n"
        "## IP library: built and checked, not all connected\n\n"
        "| block | what | file | check |\n|---|---|---|---|\n" +
        "".join(f"| {l} | {w} | `{f}` | `make {t}` |\n" for l, w, f, t in LIBRARY) + "\n"
        "## Roadmap: specified, not built\n\n"
        "| item | what | specification |\n|---|---|---|\n" +
        "".join(f"| {l} | {w} | [{d}]({pathlib.Path(d).relative_to('docs')}) |\n" for l, w, d in ROADMAP))


def render(m):
    return html(m), architecture_md()


def main():
    check_files()
    m = json.loads((ROOT / "docs/metrics.json").read_text())
    check_proof_count(m)
    page, arch = render(m)
    if "--check" in sys.argv:
        # Compare without touching the tree (SkyWater 130 audit BUILD-03).
        stale = [str(p.relative_to(ROOT)) for p, txt in ((SITE, page), (ARCH, arch))
                 if not p.exists() or p.read_text() != txt]
        if stale:
            print("site: OUT OF DATE -- run make site and commit: " + ", ".join(stale))
            sys.exit(1)
        print("site: page and architecture match the repository")
        return
    SITE.parent.mkdir(parents=True, exist_ok=True)
    SITE.write_text(page)
    ARCH.write_text(arch)
    print(f"gen_site: wrote {SITE.relative_to(ROOT)} and {ARCH.relative_to(ROOT)} "
          f"({len(AS_BUILT['blocks'])} as-built blocks checked against {AS_BUILT['plan']}, "
          f"{len(TILE_BUILT['blocks'])} tile blocks, {len(LIBRARY)} library, {len(ROADMAP)} planned)")


if __name__ == "__main__":
    main()
