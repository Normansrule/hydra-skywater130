"""
atlas_boards.py -- the atlas's Boards tab: what each FPGA image wires where, drawn from its plan.

Every figure is generated from plans/<image>.yaml (which RTL goes in, which core signal goes to which board net)
and fpga/boards/<board>.yaml (the FPGA, its clock, reset and UART balls, each pin's ball, all parsed by
tools/import_boards.py from the vendor's own constraint file). The resource figures are nextpnr's, recorded in
docs/metrics.json. Nothing here has run on a board: the page says so on every figure.

The moving light along the wires shows the path one host command takes. It is an illustration, labelled as one;
the recorded replay of an image is the FPGA section on the Overview tab.
"""
import html as H
import pathlib
import re

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
esc = lambda s: H.escape(str(s), quote=True)

BOARD_NAMES = {"ulx3s-85f": "ULX3S", "ecp5-evn": "ECP5 Evaluation Board", "arty-a7-35": "Arty A7-35",
               "basys3": "Basys 3", "tangnano20k": "Tang Nano 20K"}
ORDER = ["ulx3s-85f", "ecp5-evn-selftest", "ecp5-evn", "ecp5-evn-sys", "ecp5-evn-tpu", "ecp5-evn-two",
         "ecp5-evn-mem", "basys3", "arty-a7-35", "tangnano20k"]

# (source module, block label, caption, colour token): the order is the order a command passes through them
BLOCKS = [
    ("hydra_fpga_uart",     "UART",            "{baud} 8N1",      "control"),
    ("hydra_fpga_bridge",   "Serial bridge",   "cmd to SPI",      "control"),
    ("hydra_fpga_selftest", "Self-test",       "first light",     "ok"),
    ("hydra_tt_spi",        "SPI slave",       "mode 0",          "control"),
    ("hydra_tt_regs",       "Register map",    "host map",        "control"),
    ("mom_top",             "Scheduler",       "cost, select",    "signal"),
    ("mom_xbar",            "Crossbar",        "system tile",     "signal"),
    ("tpu_top",             "Systolic array",  "4\u00d74 INT8",   "compute"),
    ("simd_top",            "Vector unit",     "4 \u00d7 32-bit", "compute"),
    ("hydra_dma_gemm",      "Scratchpad",      "operand bank",    "memory"),
    ("hydra_fpga_jtag_host", "JTAG host",      "2nd way in",      "secure"),
]


def width(net):
    m = re.search(r"\[(\d+):(\d+)\]", net)
    return abs(int(m.group(1)) - int(m.group(2))) + 1 if m else 1


def bits(net):
    """led[7:0] -> led[0] .. led[7], lowest bit first."""
    m = re.search(r"^(.*)\[(\d+):(\d+)\]$", net)
    if not m:
        return [net]
    lo, hi = sorted((int(m.group(2)), int(m.group(3))))
    return [f"{m.group(1)}[{i}]" for i in range(lo, hi + 1)]


def directions(core):
    """Port directions of the harness module, read from its RTL: {port: input|output|inout}."""
    f = ROOT / "fpga/rtl" / f"{core}.sv"
    if not f.exists():
        return {}
    return {m.group(3): m.group(1) for m in re.finditer(
        r"\b(input|output|inout)\s+(?:wire|logic|reg)?\s*(?:signed\s*)?(\[[^\]]+\])?\s*(\w+)", f.read_text())}


def load(metrics):
    plans = {}
    res = {b["plan"]: b for b in metrics.get("boards", [])}
    for name in ORDER:
        f = ROOT / "plans" / f"{name}.yaml"
        if not f.exists():
            continue
        p = yaml.safe_load(f.read_text())
        b = yaml.safe_load((ROOT / "fpga/boards" / f"{p['board']}.yaml").read_text())
        mods = {pathlib.Path(s).stem for s in p.get("sources", [])}
        blocks = [(lab, cap.format(baud=p.get("baud", 115200)), col) for mod, lab, cap, col in BLOCKS if mod in mods]
        div = round(p["sys_hz"] / p.get("baud", 115200))
        err = (p["sys_hz"] / div - p.get("baud", 115200)) / p.get("baud", 115200) * 100
        io, dirs = [], directions(p["core"])
        for x in p.get("pins", []):
            if x["board"] in ("uart_rx", "uart_tx"):
                continue
            balls = [b["pins"].get(n, {}).get("pin", "?") for n in bits(x["board"])]
            io.append({"core": x["core"], "board": x["board"], "n": width(x["board"]), "balls": balls,
                       "role": {"input": "in", "output": "out"}.get(dirs.get(re.sub(r"\[.*", "", x["core"])), "io")})
        plans[name] = {"plan": name, "board": p["board"], "bname": BOARD_NAMES.get(p["board"], p["board"]),
                       "device": b.get("device"), "package": b.get("package", ""), "sys_hz": p["sys_hz"],
                       "osc_hz": b["clock"]["hz"], "osc_ball": b["clock"]["pin"]["pin"],
                       "reset": f'{b["reset"]["port"]} ({b["reset"]["pin"]["pin"]}), active {b["reset"]["active"]}',
                       "rx": b["uart"]["rx"]["pin"], "tx": b["uart"]["tx"]["pin"], "baud": p.get("baud", 115200),
                       "div": div, "err": err, "blocks": blocks, "io": io, "res": res.get(name),
                       "jtag": any(x["core"].startswith("jtag_") for x in p.get("pins", []))}
    return plans


def mhz(hz):
    return f"{hz / 1e6:g} MHz"


def svg(p):
    """One plan as an orthogonal wiring diagram. Each column has fixed coordinates, so labels never meet."""
    blocks = [b for b in p["blocks"] if b[0] != "JTAG host"]
    row1, row2 = blocks[:5], blocks[5:]
    bw, bh, gap = 122, 66, 14
    fx0, fy0 = 250, 150
    fx1 = fx0 + 14 + 5 * bw + 4 * gap + 44          # room on the right for the pin bus
    bus = fx1 - 22
    io_rows = [x for x in p["io"] if not x["core"].startswith("jtag_")]
    lx, lw, rh = fx1 + 70, 310, 96
    W = lx + lw + 20
    fy1 = max(fy0 + (262 if row2 or p["jtag"] else 176), fy0 + rh * len(io_rows) - 6)
    H_ = max(fy1 + 30, 500 if p["jtag"] else 400)
    mk = f'marker-end="url(#ah-{p["plan"]})"'
    o = [f'<svg viewBox="0 0 {W} {H_}" class="bd" role="img" aria-labelledby="bd-{p["plan"]}-cap">',
         f'<defs><marker id="ah-{p["plan"]}" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" '
         f'orient="auto"><path d="M0,0 L8,4 L0,8 z" class="bd-ah"/></marker></defs>']
    box = lambda x, y, w, h, cls, l1, l2="": (
        f'<g class="bd-box {cls}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8"/>'
        f'<text x="{x + 12}" y="{y + 24}" class="bd-t">{esc(l1)}</text>' +
        (f'<text x="{x + 12}" y="{y + 44}" class="bd-s">{esc(l2)}</text>' if l2 else "") + "</g>")
    # host side: the PC, and the board's own USB serial chip
    o.append(box(20, 190, 170, 64, "c-host", "PC", "tools/hydra_host.py"))
    o.append(box(20, 300, 170, 64, "c-host", "USB serial chip", "on the board"))
    o.append('<path class="bd-w" d="M105,254 V300"/>')
    # clock and reset, above the FPGA
    o.append(box(fx0, 20, 260, 64, "c-clk", f"Oscillator {mhz(p['osc_hz'])}", f"ball {p['osc_ball']}"))
    o.append(box(fx0 + 290, 20, 300, 64, "c-clk", "Reset", p["reset"]))
    o.append(f'<path class="bd-w" d="M{fx0 + 130},84 V{fy0}" {mk}/><path class="bd-w" d="M{fx0 + 440},84 V{fy0}" {mk}/>')
    # the FPGA and the blocks the image compiles in
    o.append(f'<g class="bd-fpga"><rect x="{fx0}" y="{fy0}" width="{fx1 - fx0}" height="{fy1 - fy0}" rx="12"/>'
             f'<text x="{fx0 + 14}" y="{fy0 + 26}" class="bd-t">{esc(p["device"])} {esc(p["package"])}</text>'
             f'<text x="{fx1 - 14}" y="{fy0 + 26}" class="bd-s" text-anchor="end">system clock {mhz(p["sys_hz"])}</text></g>')
    pos = {}
    for i, (lab, cap, col) in enumerate(row1):
        pos[lab] = (fx0 + 14 + i * (bw + gap), fy0 + 50)
        o.append(box(*pos[lab], bw, bh, f"c-{col} bd-blk", lab, cap))
    for i, (lab, cap, col) in enumerate(row2):
        pos[lab] = (fx0 + 14 + (i + 1) * (bw + gap), fy0 + 166)
        o.append(box(*pos[lab], bw, bh, f"c-{col} bd-blk", lab, cap))
    lane = lambda lab: pos[lab][1] + bh - 9           # wires run below each block's caption
    for row in (row1, row2):
        for a_, b_ in zip(row, row[1:]):
            ax, _ = pos[a_[0]]
            o.append(f'<path class="bd-w" d="M{ax + bw},{lane(a_[0])} H{ax + bw + gap}" {mk}/>')
    if row1 and row2:   # the scheduler hands jobs down to the crossbar and its engines
        sx, sy = pos[row1[-1][0]]
        cx, cy = pos[row2[0][0]]
        o.append(f'<path class="bd-w" d="M{sx + bw / 2},{sy + bh} V{sy + bh + 25} H{cx + bw / 2} V{cy}" {mk}/>')
    # serial: rx comes up into the UART block, tx goes back down from it
    ux, uy = pos[row1[0][0]]
    o.append(f'<path class="bd-w" d="M190,320 H{ux + 30} V{uy + bh}" {mk}/>'
             f'<path class="bd-w" d="M{ux + 60},{uy + bh} V350 H190" {mk}/>'
             f'<text x="200" y="312" class="bd-s">rx {esc(p["rx"])}</text><text x="200" y="368" class="bd-s">tx {esc(p["tx"])}</text>')
    # JTAG: a probe on the header, into its own host block, which feeds the bridge's command decoder
    if p["jtag"]:
        jt = [x for x in p["io"] if x["core"].startswith("jtag_")]
        o.append(box(20, 410, 170, 64, "c-secure", "JTAG probe", "TCK TMS TDI TDO"))
        jx, jy = fx0 + 14 + bw + gap, fy0 + 166
        o.append(box(jx, jy, bw, bh, "c-secure bd-blk", "JTAG host", "2nd way in"))
        o.append(f'<path class="bd-w" d="M190,442 H{jx + bw / 2} V{jy + bh}" {mk}/>'
                 f'<text x="200" y="462" class="bd-s">{esc(" ".join(x["balls"][0] for x in jt))}</text>')
        bx, by = pos.get("Serial bridge", (ux, uy))
        o.append(f'<path class="bd-w" d="M{jx + bw / 2},{jy} V{by + bh}" {mk}/>')
    # board peripherals on the right, one row per mapped net, fed from a bus at the FPGA's right edge
    ys = [fy0 + i * rh for i in range(len(io_rows))]
    pulse_to = None
    for y, x in zip(ys, io_rows):
        n = x["n"]
        dots = "".join(f'<circle cx="{lx + 18 + (k % 8) * 16}" cy="{y + 50 + (k // 8) * 14}" r="5" class="bd-dot" '
                       f'style="--k:{k}"/>' for k in range(min(n, 16)))
        span = x["balls"][0] if n == 1 else f'{x["balls"][0]} … {x["balls"][-1]}'
        o.append(f'<g class="bd-box c-io{" bd-led" if x["board"].startswith("led") else ""}">'
                 f'<rect x="{lx}" y="{y}" width="{lw}" height="84" rx="8"/>'
                 f'<text x="{lx + 12}" y="{y + 22}" class="bd-t">{esc(x["board"])}</text>'
                 f'<text x="{lx + lw - 12}" y="{y + 22}" class="bd-s" text-anchor="end">{esc(x["core"])}</text>'
                 f'<text x="{lx + lw - 12}" y="{y + 74}" class="bd-s" text-anchor="end">balls {esc(span)}</text>{dots}</g>')
        if x["role"] == "in":
            o.append(f'<path class="bd-w" d="M{lx},{y + 42} H{bus}" {mk}/>')
        else:
            o.append(f'<path class="bd-w" d="M{bus},{y + 42} H{lx}" {mk}/>')
        if pulse_to is None and x["board"].startswith("led"):
            pulse_to = y + 42
    last = row1[-1][0] if row1 else None
    if last and io_rows:
        lx0, _ = pos[last]
        ly = lane(last)
        top, bot = min([ly] + [y + 42 for y in ys]), max([ly] + [y + 42 for y in ys])
        o.append(f'<path class="bd-w" d="M{lx0 + bw},{ly} H{bus}"/><path class="bd-w bd-bus" d="M{bus},{top} V{bot}"/>')
    # one command's path, as an animated light: PC, USB, rx, the chain, out along the bus to the LEDs
    if row1:
        pts = [(190, 320), (ux + 30, 320), (ux + 30, lane(row1[0][0]))]
        pts += [(pos[b_[0]][0] + bw, lane(b_[0])) for b_ in row1]
        if pulse_to is not None:
            pts += [(bus, pts[-1][1]), (bus, pulse_to), (lx, pulse_to)]
        d = "M105,254 V300 M" + " L".join(f"{x:.0f},{y:.0f}" for x, y in pts)
        o.append(f'<path class="bd-pulse" d="{d}" pathLength="100"/>')
    o.append("</svg>")
    return "".join(o)


def section(metrics):
    plans = load(metrics)
    if not plans:
        return ""
    btns, figs = [], []
    for i, (name, p) in enumerate(plans.items()):
        chain = " → ".join(b[0] for b in p["blocks"])
        btns.append(f'<button type="button" data-plan="{name}" aria-pressed="{"true" if i == 0 else "false"}">'
                    f'{esc(name)}</button>')
        r = p["res"]
        res = (f'{r["luts"]:,} LUTs, {r["ffs"]:,} flip-flops, {r["mult"]} multipliers; Fmax {r["fmax"]:g} MHz '
               f'(nextpnr, recorded in <code>docs/metrics.json</code>)' if r else "not recorded in docs/metrics.json")
        rows = "".join(f'<tr><td><code>{esc(x["core"])}</code></td><td><code>{esc(x["board"])}</code></td>'
                       f'<td>{esc(" ".join(x["balls"]))}</td></tr>' for x in p["io"])
        figs.append(
            f'<figure class="bdfig" data-plan="{name}">'
            f'<figcaption id="bd-{name}-cap"><b>{esc(p["bname"])}</b>, image <code>{esc(name)}</code>: '
            f'{esc(chain)}. Wiring from <code>plans/{esc(name)}.yaml</code> and '
            f'<code>fpga/boards/{esc(p["board"])}.yaml</code>. The moving light is an illustration of one command\'s '
            f'path, not a recording. <b>Not yet run on a board.</b></figcaption>'
            f'<div class="bdstage">{svg(p)}</div>'
            f'<dl class="bdfacts"><dt>FPGA</dt><dd>{esc(p["device"])} {esc(p["package"])}</dd>'
            f'<dt>Clock</dt><dd>{mhz(p["osc_hz"])} oscillator on ball {esc(p["osc_ball"])}, system clock {mhz(p["sys_hz"])}</dd>'
            f'<dt>Serial</dt><dd>{p["baud"]:,} baud: {p["div"]} clocks per bit, {p["err"]:+.2f}% from nominal</dd>'
            f'<dt>Resources</dt><dd>{res}</dd>'
            f'<dt>Status</dt><dd>Built and checked in simulation; never run on a board</dd></dl>'
            f'<details class="bdtext"><summary>The same wiring as a table</summary><div class="tablewrap"><table>'
            f'<thead><tr><th>Core signal</th><th>Board net</th><th>FPGA balls</th></tr></thead><tbody>'
            f'<tr><td><code>uart_rx_i</code></td><td><code>uart_rx</code></td><td>{esc(p["rx"])}</td></tr>'
            f'<tr><td><code>uart_tx_o</code></td><td><code>uart_tx</code></td><td>{esc(p["tx"])}</td></tr>'
            f'{rows}</tbody></table></div></details></figure>')
    return (f'<div class="bdpick" role="group" aria-label="FPGA image">{"".join(btns)}</div>{"".join(figs)}')


CSS = r"""
.bdpick{display:flex;flex-wrap:wrap;gap:6px;margin:var(--sp-3) 0}
.bdpick button{font:var(--fs-1) var(--mono);background:var(--surface);color:var(--ink2);border:0;border-radius:6px;padding:6px 10px;min-height:34px;cursor:pointer}
.bdpick button[aria-pressed="true"]{background:var(--raised);color:var(--ink);box-shadow:inset 0 -2px 0 var(--signal)}
.bdpick button:focus-visible{outline:2px solid var(--control);outline-offset:2px}
.bdfig{margin:0 0 var(--sp-5)}
.bdfig figcaption{color:var(--ink2);max-width:72ch;margin-bottom:var(--sp-3)}
.bdstage{background:var(--die-sub);border-radius:var(--r);padding:var(--sp-3);overflow-x:auto}
.bd{display:block;width:100%;min-width:960px;height:auto}
.bd .bd-box rect{fill:#12151b;stroke:#2a303a;stroke-width:1}
.bd .bd-fpga rect{fill:#0d1016;stroke:#3a4250;stroke-width:1.5}
.bd .bd-t{fill:#ece9e0;font:600 15px var(--sans)}
.bd .bd-s{fill:#9aa0a8;font:12px var(--mono)}
.bd .bd-w{fill:none;stroke:#4a5260;stroke-width:1.6}
.bd .bd-ah{fill:#4a5260}
.bd .c-control rect{stroke:var(--control)}.bd .c-signal rect{stroke:var(--signal)}.bd .c-compute rect{stroke:var(--compute)}
.bd .c-memory rect{stroke:var(--memory)}.bd .c-secure rect{stroke:var(--secure)}.bd .c-ok rect{stroke:var(--ok)}
.bd .bd-dot{fill:#2a303a}
.bd .bd-pulse{fill:none;stroke:var(--signal);stroke-width:3;stroke-linecap:round;stroke-dasharray:6 94;filter:drop-shadow(0 0 6px var(--signal));
  animation:bdrun 3.6s linear infinite}
@keyframes bdrun{from{stroke-dashoffset:100}to{stroke-dashoffset:0}}
.bd .bd-led .bd-dot{animation:bdled 3.6s steps(1) infinite;animation-delay:calc(var(--k) * 40ms)}
@keyframes bdled{0%,72%{fill:#2a303a}76%,96%{fill:var(--signal)}}
.bdfacts{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;margin:var(--sp-3) 0}
.bdfacts dt{color:var(--ink2)}.bdfacts dd{margin:0}
@media (prefers-reduced-motion:reduce){.bd .bd-pulse{animation:none;stroke-dasharray:none;opacity:.5}.bd .bd-led .bd-dot{animation:none}}
@media print{.bd .bd-pulse{display:none}}
"""

JS = r"""
(()=>{
// the Boards tab's picker: one image's figure at a time; without script every figure shows
const pick=document.querySelector('.bdpick');if(!pick)return;
const figs=[...document.querySelectorAll('.bdfig')];
pick.addEventListener('click',e=>{const b=e.target.closest('button[data-plan]');if(!b)return;
  pick.querySelectorAll('button').forEach(x=>x.setAttribute('aria-pressed',x===b));
  figs.forEach(f=>f.hidden=f.dataset.plan!==b.dataset.plan)});
figs.forEach((f,i)=>f.hidden=i>0);
})();
"""


# The README's copy: one image (the next bring-up board) as a self-contained SVG in both themes. GitHub shows SVG
# through <img>, so the page's CSS is not there: the same rules travel inside the figure, with @tokens that
# atlas_theme.variants paints for light and dark.
README_PLAN = "ulx3s-85f"
README_STYLE = (
    "<style>"
    ".bd-box rect{fill:@surface;stroke:@line;stroke-width:1}.bd-fpga rect{fill:@bg;stroke:@line;stroke-width:1.5}"
    ".bd-t{fill:@ink;font:600 15px 'Ubuntu Sans',ui-sans-serif,system-ui,sans-serif}"
    ".bd-s{fill:@dim;font:12px 'Ubuntu Sans Mono',ui-monospace,Menlo,Consolas,monospace}"
    ".bd-w{fill:none;stroke:@dim;stroke-width:1.6}.bd-ah{fill:@dim}"
    ".c-control rect{stroke:@control}.c-signal rect{stroke:@signal}.c-compute rect{stroke:@compute}"
    ".c-memory rect{stroke:@memory}.c-secure rect{stroke:@secure}.c-ok rect{stroke:@ok}"
    ".bd-dot{fill:@line}"
    ".bd-pulse{fill:none;stroke:@signal;stroke-width:3;stroke-linecap:round;stroke-dasharray:6 94;animation:r 3.6s linear infinite}"
    "@keyframes r{from{stroke-dashoffset:100}to{stroke-dashoffset:0}}"
    ".bd-led .bd-dot{animation:l 3.6s steps(1) infinite;animation-delay:calc(var(--k) * 40ms)}"
    "@keyframes l{0%,72%{fill:@line}76%,96%{fill:@signal}}"
    "@media (prefers-reduced-motion:reduce){.bd-pulse{animation:none;stroke-dasharray:none;opacity:.5}.bd-led .bd-dot{animation:none}}"
    "</style>")


def readme_svg(metrics):
    p = load(metrics)[README_PLAN]
    s = svg(p)
    vb = re.search(r'viewBox="0 0 (\d+) (\d+)"', s)
    w, h = int(vb.group(1)), int(vb.group(2)) + 34
    s = s.replace(f'viewBox="0 0 {vb.group(1)} {vb.group(2)}" class="bd" role="img" aria-labelledby="bd-{README_PLAN}-cap">',
                  f'xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" '
                  f'aria-label="{esc(p["bname"])} wiring for image {README_PLAN}">' + README_STYLE +
                  f'<rect width="{w}" height="{h}" rx="16" fill="@bg"/>', 1)
    note = (f'{p["bname"]}, image {README_PLAN}: from plans/{README_PLAN}.yaml and fpga/boards/{p["board"]}.yaml. '
            f'The moving light is an illustration, not a recording. Not yet run on a board.')
    return s.replace("</svg>", f'<text x="20" y="{h - 14}" class="bd-s">{esc(note)}</text></svg>')


def main():
    import json, sys
    sys.path.insert(0, str(ROOT / "tools"))
    import atlas_theme as T
    metrics = json.loads((ROOT / "docs/metrics.json").read_text())
    stale = []
    for name, text in T.variants("boards.svg", readme_svg(metrics)):
        f = ROOT / "docs/img" / name
        if "--check" in sys.argv:
            if not f.exists() or f.read_text() != text:
                stale.append(name)
        else:
            f.write_text(text)
    if stale:
        sys.exit(f"readme-boards: {', '.join(stale)} out of date with the plan and board files -- run: python3 tools/atlas_boards.py")
    print("readme-boards: the board wiring figure matches plans/ and fpga/boards/" if "--check" in sys.argv
          else "atlas_boards: wrote docs/img/boards.svg and boards.dark.svg")


if __name__ == "__main__":
    main()
