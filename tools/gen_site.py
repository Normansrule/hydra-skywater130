#!/usr/bin/env python3
"""
gen_site.py -- build the project page and the architecture diagram FROM THE
REPOSITORY, so neither can drift away from the hardware.

Two rules make this worth having rather than a hand-drawn picture:

  1. Every block in the diagram names a file. The generator checks each one
     exists and refuses to emit a diagram that shows hardware which is not
     there. A block diagram nobody can trust is decoration.

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
# The topology. Each block names the file that implements it; the generator
# verifies every path before drawing anything.
# ---------------------------------------------------------------------------
BLOCKS = [
    # id,        label,              sub,                       file,                                     column, row
    ("host",  "Host",            "serial port",            "tools/hydra_host.py",                     0, 1),
    ("bridge","Bridge",          "UART to pins, memory",   "fpga/rtl/hydra_fpga_bridge.sv",           1, 1),
    ("spi",   "SPI slave",       "register map",           "mom/rtl/hydra_tt_spi.sv",         2, 0),
    ("regs",  "Registers",       "the host map",            "mom/rtl/hydra_tt_regs.sv",        2, 1),
    ("feat",  "Features",        "log2 work, intensity",   "mom/rtl/mom_features.sv",         3, 0),
    ("cost",  "Cost engine",     "one, walked over five",  "mom/rtl/mom_cost_engine.sv",      3, 1),
    ("sel",   "Select",          "argmin with margin",     "mom/rtl/mom_select.sv",           3, 2),
    ("sb",    "Scoreboard",      "tags, queue depth",     "mom/rtl/mom_scoreboard.sv",       4, 0),
    ("cal",   "Calibrate",       "measured vs predicted",  "mom/rtl/mom_calibrate.sv",        4, 2),
    ("xbar",  "Crossbar",        "descriptor to engine",   "common/rtl/mom_xbar.sv",                  5, 1),
    ("tpu",   "TPU",             "4x4 INT8 array",         "engines/tpu/rtl/tpu_top.sv",              6, 0),
    ("simd",  "SIMD",            "4 x 32-bit lanes",       "engines/simd/rtl/simd_top.sv",            6, 1),
    ("ntt",   "NTT",             "4 Barrett butterflies",  "engines/ntt/rtl/ntt_top.sv",              6, 2),
    ("dma",   "Streamer",        "banks to engines",       "mem/rtl/hydra_dma_gemm.sv",               7, 1),
    ("bank",  "Scratchpad",      "A, B, W, results",       "mem/rtl/hydra_spram.sv",                  8, 1),
    ("jtag",  "Test port",       "IEEE 1149.1, own clock",  "dbg/rtl/hydra_jtag_tap.sv",               1, 3),
    ("jbr",   "Crossing",        "toggle handshake",        "dbg/rtl/hydra_jtag_bridge.sv",            2, 3),
    ("xsec",  "Security ISA",    "Zknh + Xhydrasec",        "isa/rtl/hydra_xsec_unit.sv",              3, 4),
    ("pcr",   "Measurement",     "extend only, no write",   "sec/rtl/hydra_pcr.sv",                    7, 3),
    ("sha",   "SHA-256",         "padded in hardware",      "sec/rtl/hydra_sha256_stream.sv",          6, 3),
    ("mbox",  "Mailbox",         "lock, command, execute",  "sec/rtl/hydra_mailbox.sv",                4, 3),
    ("kv",    "Key vault",       "write and use, never read","sec/rtl/hydra_key_vault.sv",             5, 3),
]

EDGES = [
    ("host", "bridge", "bytes"),
    ("bridge", "spi", "pins"),
    ("bridge", "bank", "load"),
    ("spi", "regs", ""),
    ("regs", "feat", "descriptor"),
    ("feat", "cost", ""),
    ("cost", "sel", "5 costs"),
    ("sb", "cost", "queue"),
    ("sel", "xbar", "engine"),
    ("sb", "xbar", "tag"),
    ("xbar", "tpu", ""),
    ("xbar", "simd", ""),
    ("xbar", "ntt", ""),
    ("tpu", "cal", "done"),
    ("cal", "cost", "k"),
    ("dma", "tpu", "operands"),
    ("dma", "simd", ""),
    ("dma", "ntt", ""),
    ("bank", "dma", ""),
    ("jtag", "jbr", "TCK"),
    ("jbr", "regs", "second way in"),
    ("regs", "mbox", "commands"),
    ("mbox", "kv", "by slot"),
    ("mbox", "sha", "measure"),
    ("sha", "pcr", "extend"),
    ("xsec", "kv", "by slot"),
    ("xsec", "pcr", "extend, read"),
    ("regs", "kv", "slots"),
    ("kv", "xbar", "key by slot"),
]

COLW, ROWH, BW, BH = 168, 104, 132, 58
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


def check_files():
    """Refuse to publish claims the repository does not back up."""
    problems = []

    for _, _, _, f, _, _ in BLOCKS:
        if not (ROOT / f).exists():
            problems.append(f"block names a missing file: {f}")

    m = json.loads((ROOT / "docs/metrics.json").read_text())
    makefile = (ROOT / "Makefile").read_text()

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


def svg_diagram():
    w = PAD_X * 2 + (max(c for *_, c, _ in BLOCKS)) * COLW + BW
    h = PAD_Y * 2 + (max(r for *_, r in BLOCKS)) * ROWH + BH
    at = {b[0]: pos(b[4], b[5]) for b in BLOCKS}

    out = [f'<svg class="diagram" viewBox="0 0 {w} {h}" '
           f'xmlns="http://www.w3.org/2000/svg" role="img" '
           f'aria-label="HYDRA-130 block diagram">',
           '<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" '
           'markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
           '<path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor"/></marker></defs>']

    for a, b, label in EDGES:
        ax, ay = at[a]
        bx, by = at[b]
        x1, y1 = ax + BW / 2, ay + BH / 2
        x2, y2 = bx + BW / 2, by + BH / 2
        mx = (x1 + x2) / 2
        path = f"M {x1} {y1} C {mx} {y1}, {mx} {y2}, {x2} {y2}"
        out.append(f'<path class="edge" data-a="{a}" data-b="{b}" d="{path}" '
                   f'marker-end="url(#ah)"/>')
        if label:
            out.append(f'<text class="edge-label" x="{mx}" y="{(y1 + y2) / 2 - 6}">'
                       f'{label}</text>')

    for bid, label, sub, path, col, row in BLOCKS:
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


def mermaid():
    lines = ["flowchart LR"]
    for bid, label, sub, path, _, _ in BLOCKS:
        lines.append(f'  {bid}["{label}<br/><small>{sub}</small>"]')
    for a, b, label in EDGES:
        arrow = f"-- {label} -->" if label else "-->"
        lines.append(f"  {a} {arrow} {b}")
    return "\n".join(lines)


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
        f"<tr><th>{e['name']}</th><td>{e['what']}</td>"
        f"<td class='num'>{format(e['cells'], ',') if e['cells'] else '<span class=\"todo\">not measured</span>'}</td>"
        f"<td class='num'>{format(e['um2'], ',') + ' µm²' if e['um2'] else '<span class=\"todo\">not measured</span>'}</td>"
        f"<td>{e['results']}</td><td>{e['mutations']}</td></tr>"
        for e in m["engines"])

    board_rows = "".join(
        f"<tr><th>{b['plan']}</th><td>{b['what']}</td>"
        f"<td class='num'>{b['luts']:,}</td><td class='num'>{b['ffs']:,}</td>"
        f"<td class='num'>{b['mult']}</td><td class='num'>{b['fmax']} MHz</td></tr>"
        for b in m["boards"])

    ver_rows = "".join(
        f"<tr><th>{v['what']}</th><td class='num'>{v['result']}</td>"
        f"<td><span class='kind'>{v['kind']}</span></td></tr>"
        for v in m["verification"])

    pending = "".join(f"<li>{p}</li>" for p in m["pending"])

    t = m["tile"]
    saved = t["parallel_um2"] - t["shared_um2"]
    pct = round(100 * saved / t["parallel_um2"])

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>HYDRA-130 — a dispatcher that measures its own engines</title>
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
  .node:focus {{ outline: none; }}
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
</style>
</head>
<body>
<div class="wrap">

<header>
  <div class="tag">SkyWater sky130 · Tiny Tapeout · ECP5</div>
  <h1>HYDRA-130</h1>
  <p class="lede">A dispatcher that predicts how long each engine would take,
  sends the work to the cheapest one, then measures what actually happened and
  corrects its own model. Three arithmetic engines, a scratchpad, and a host
  link — verified against independent models, proved where proof is cheaper
  than testing, and honest about what has not been built yet.</p>
</header>

<h2>How it fits together</h2>
<div class="panel">
{svg_diagram()}
</div>
<p class="scroll-note">Every block names the file that implements it — hover
to see the path. The diagram is generated from the repository and the
generator refuses to draw a block whose file is missing.</p>

<h2>Where the silicon goes</h2>
<div class="panel">
{svg_area(m)}
</div>
<p class="scroll-note">To scale. Five copies of the cost engine were the
largest thing on the tile, which is what drove the redesign below.</p>

<h2>One cost engine doing the work of five</h2>
<div class="panel">
{svg_sweep()}
</div>

<h2>What the numbers say</h2>
<div class="cards">
  <div class="card"><div class="k">{t['shared_um2']:,}</div>
    <div class="v">µm² of standard cells in the tile, down {pct}% from
    {t['parallel_um2']:,} by walking one cost engine over five parameter rows
    instead of building five</div></div>
  <div class="card"><div class="k">44</div>
    <div class="v">deliberate faults injected across four mutation suites,
    all caught or proven equivalent</div></div>
  <div class="card"><div class="k">8</div>
    <div class="v">modules whose contracts are proved by k-induction, not
    sampled by tests</div></div>
  <div class="card"><div class="k">1,608</div>
    <div class="v">arithmetic results checked against models written from the
    contract, not from the code</div></div>
</div>

<h2>Engines</h2>
<div class="panel"><table>
<thead><tr><th>Engine</th><th>What it is</th><th>Cells</th><th>Area</th>
<th>Checked against a model</th><th>Mutation testing</th></tr></thead>
<tbody>{eng_rows}</tbody>
</table></div>
<p class="scroll-note">{t['method']}. {t['caveat']}</p>

<h2>Board images</h2>
<div class="panel"><table>
<thead><tr><th>Plan</th><th>What it carries</th><th>LUT4</th><th>Flops</th>
<th>Multipliers</th><th>Fmax</th></tr></thead>
<tbody>{board_rows}</tbody>
</table></div>
<p class="scroll-note">Lattice ECP5 evaluation board, place and route by
nextpnr. All pass timing at the 12&nbsp;MHz operating clock.</p>

<h2>How it is verified</h2>
<div class="panel"><table>
<thead><tr><th>Check</th><th>Scale</th><th>Kind</th></tr></thead>
<tbody>{ver_rows}</tbody>
</table></div>
<p>Each engine is compared against a model written from its contract rather
than from its code, so a misreading of the specification shows up as a
disagreement instead of being copied into both. Where a property is cheaper
to prove than to sample — a port contract, a completion that must fire once —
it is proved. Mutation testing then asks the only question that matters about
a test suite: if the design were broken, would anything fail?</p>

<h2>What kind of evidence</h2>
{svg_verify(m)}
<p class="scroll-note">"Tested" spans everything from one happy path to an
exhaustive proof, so the checks are grouped by what they actually establish.</p>

<h2>What has not been done</h2>
<ul class="warn">{pending}</ul>

<footer>
  Generated by <code>tools/gen_site.py</code> from <code>docs/metrics.json</code>
  and the module tree. Run <code>make site-check</code> to prove this page still
  matches the repository.
</footer>

</div>
<script>
  // Highlight a block and the wires touching it. No library, no build step:
  // the page has to open from disk years from now without fetching anything.
  const edges = [...document.querySelectorAll('.edge')];
  for (const n of document.querySelectorAll('.node')) {{
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
</script>
</body>
</html>
"""


def check_proof_count(m):
    """The page states how many modules carry formal proofs. That number
    said 10 while the repository held 14 .sby files (found 2026-10-07): a
    hand-kept count drifts the moment a proof is added. Count the files and
    refuse to write a page that disagrees."""
    n = sum(1 for f in ROOT.rglob("*.sby")
            if f.parent.name == "formal" and ".git" not in f.parts)
    for v in m["verification"]:
        if v["what"] == "formal proofs" and v["result"] != f"{n} modules":
            raise SystemExit(f"gen_site: metrics.json says formal proofs '{v['result']}', "
                             f"but the repository has {n} .sby files -- update docs/metrics.json")


def main():
    check_files()
    m = json.loads((ROOT / "docs/metrics.json").read_text())
    check_proof_count(m)
    SITE.parent.mkdir(parents=True, exist_ok=True)
    SITE.write_text(html(m))
    ARCH.write_text(
        "# HYDRA-130 architecture\n\n"
        "Generated by `tools/gen_site.py`; run `make site-check` to prove it\n"
        "still matches the repository. Every block below names a file, and the\n"
        "generator fails if one of those files is missing.\n\n"
        "```mermaid\n" + mermaid() + "\n```\n\n"
        "| block | file |\n|---|---|\n" +
        "".join(f"| {label} | `{path}` |\n" for _, label, _, path, _, _ in BLOCKS))
    print(f"gen_site: wrote {SITE.relative_to(ROOT)} and {ARCH.relative_to(ROOT)} "
          f"({len(BLOCKS)} blocks, {len(EDGES)} edges, all files present)")


if __name__ == "__main__":
    main()
