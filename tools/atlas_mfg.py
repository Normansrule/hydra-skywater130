"""
atlas_mfg.py -- the atlas's Manufacturing tab and the README's manufacturing table, from docs/tapeout/facts.json.

Every value shown is read from the fact sheet that tools/tapeout_facts.py writes from tool output and the PDK; each
one carries the exact command that reproduces it and the file it comes from, and both are shown beside it. A fact
the sheet marks "not available" (the I/O pad pitch, until Caravel's padframe DEF is fetched) is shown as pending,
never as a number. Nothing here is typed by hand except the words around the facts.

  python3 tools/atlas_mfg.py            rewrite the README block between the manufacturing markers
  python3 tools/atlas_mfg.py --check    fail if that block no longer matches the fact sheet
"""
import html as H
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FACTS = ROOT / "docs/tapeout/facts.json"
esc = lambda s: H.escape(str(s), quote=True)
TITLES = {"tt_tile": "Tiny Tapeout tile", "openframe_core": "OpenFrame core (hardened block)"}
START, END = "<!-- manufacturing:start -->", "<!-- manufacturing:end -->"


def load():
    if not FACTS.exists():
        return None
    return json.loads(FACTS.read_text())["targets"]


def fact(t, name):
    return next((f for f in t["facts"] if f["name"] == name), None)


def fmt(f):
    """The value as it should read: numbers to sensible places, pending when the sheet has none."""
    if f is None or f["kind"] == "not available" or f["value"] is None:
        return None
    v, u = f["value"], (f.get("unit") or "").strip()
    if isinstance(v, float):
        v = f"{v:.4f}".rstrip("0").rstrip(".") if abs(v) < 100 else f"{v:,.0f}"
        if u == "" and 0 < float(f["value"]) < 1 and "utilisation" in f["name"]:
            return f"{float(f['value']) * 100:.1f}%"
    elif isinstance(v, int):
        v = f"{v:,}"
    if u in ("ns",) and isinstance(f["value"], (int, float)) and f["value"] >= 0:
        v = "+" + v
    # the sheet writes units in ASCII (um, mm2); shown with their proper symbols
    u = {"um": "µm", "mm2": "mm²", "um2": "µm²"}.get(u, u)
    if isinstance(v, str) and " x " in v:
        v = v.replace(" x ", " × ")
    return f"{v} {u}".strip()


def src_html(f):
    if f is None:
        return ""
    return (f'<details class="mf-src"><summary>source</summary><p><span class="kind">{esc(f["kind"])}</span>'
            + (f' <code>{esc(f["source_file"])}</code>' if f.get("source_file") else "")
            + f'</p><pre><code>{esc(f["command"])}</code></pre>'
            + (f'<p class="small">{esc(f["note"])}</p>' if f.get("note") else "") + "</details>")


def row(t, name, label=None):
    f = fact(t, name)
    v = fmt(f)
    shown = f'<span class="mf-pending">pending</span>' if v is None else esc(v)
    return f'<tr><th scope="row">{esc(label or name)}</th><td>{shown}{src_html(f)}</td></tr>'


KEY = [("die width x height", "Die"), ("die area", "Die area"), ("Tiny Tapeout 4x4 slot", "Tiny Tapeout slot"),
       ("process / PDK", "Process and PDK"), ("PDK version (open_pdks commit)", "PDK version (open_pdks)"),
       ("tile pins", "Pins"), ("chip I/O (OpenFrame)", "Chip I/O"), ("package", "Package"),
       ("signal routing layers used", "Metal layers routed"), ("power grid layers", "Power grid"),
       ("top metal layer a TT project may use", "Top metal allowed (TT)"),
       ("additional IP inside the core", "IP inside the design"),
       ("additional IP on the TT chip (not in this design)", "IP the chip around it adds"),
       ("additional IP on the OpenFrame chip (not in this design)", "IP the chip around it adds")]
PITCH = [("I/O pad pitch", "I/O pad pitch"), ("GPIO pad cell (sky130_ef_io__gpiov2_pad_wrapped) width x height",
                                               "GPIO pad cell (the pitch cannot be smaller than its width)")]
POWER = [("core supply (standard cells VPWR)", "Core (VPWR)"), ("ground (VGND)", "Core ground (VGND)"),
         ("I/O pad supply (VDDIO)", "I/O pads (VDDIO)"), ("I/O pad core-side supply (VCCD)", "I/O pad core side (VCCD)"),
         ("I/O pad ground (VSS)", "I/O ground (VSS)")]
SIGN = [("Magic DRC", "Design rules (Magic)"), ("route DRC", "Design rules (router)"), ("LVS errors", "Layout vs schematic"),
        ("antenna violating nets", "Antenna"), ("illegal overlaps", "Illegal overlaps"), ("disconnected pins", "Disconnected pins"),
        ("worst setup slack, all corners", "Worst setup slack"), ("worst hold slack, all corners", "Worst hold slack"),
        ("core utilisation", "Core utilisation")]
OPEN = [("max slew violations, all corners", "Slew"), ("max capacitance violations, all corners", "Capacitance"),
        ("max fanout violations, all corners", "Fanout")]


def table(t, items, cap):
    rows = "".join(row(t, n, l) for n, l in items if fact(t, n))
    return f'<div class="tablewrap"><table class="mf"><caption>{esc(cap)}</caption><tbody>{rows}</tbody></table></div>' if rows else ""


def section():
    T = load()
    if not T:
        return ('<p class="callout warn">The tapeout fact sheet (<code>docs/tapeout/facts.json</code>) is not in this '
                'build of the page.</p>')
    out = []
    for key, t in T.items():
        warn = [(l, fmt(fact(t, n))) for n, l in OPEN if fact(t, n)]
        open_txt = ", ".join(f"{l.lower()} {v}" for l, v in warn if v and v != "0")
        out.append(
            f'<section class="mf-target" aria-labelledby="mf-{key}"><h3 id="mf-{key}">{esc(TITLES.get(key, key))}</h3>'
            f'<p class="small">Run <code>{esc(t["run"])}</code>. Values below are read from it and from the PDK by '
            f'<code>tools/tapeout_facts.py</code>; open <b>source</b> on any value for the command that reproduces it.</p>'
            + table(t, KEY, "Die, process, pins and layers")
            + table(t, PITCH, "I/O cell pitch")
            + table(t, POWER, "Power domains")
            + table(t, SIGN, "Sign-off")
            + (f'<p class="callout warn"><b>Open warnings, not zero:</b> {esc(open_txt)} (maximum over all corners). '
               f'They are design-rule warnings from timing analysis, not layout or LVS errors; each is listed with its '
               f'source in the table below.</p>' if open_txt else "")
            + table(t, OPEN, "Electrical warnings")
            + "</section>")
    return "".join(out)


INTRO = ('<p>What it takes to manufacture each target, read from the hardened runs and the process design kit. '
         'The Tiny Tapeout tile is one design on Tiny Tapeout\'s shared chip: Tiny Tapeout supplies the padframe, the '
         'package and the power. The OpenFrame core is a hardened block for a full SkyWater 130 OpenFrame chip, which '
         'brings its own padframe; it has not been manufactured. <b>The I/O pad pitch is pending</b>: it is read from '
         'the padframe\'s own layout (Caravel\'s <code>chip_io.def</code> and <code>openframe_project_wrapper.def</code>), '
         'which is not fetched yet. Until then the only number shown is the pad cell\'s width, the floor the pitch '
         'cannot go below.</p>')


CSS = r"""
.mf{width:100%}.mf caption{text-align:left;font-weight:600;padding:var(--sp-3) 0 var(--sp-2);color:var(--ink)}
.mf th{width:38%;font-weight:500;color:var(--ink2);vertical-align:top}.mf td{vertical-align:top}
.mf-src{margin-top:4px}.mf-src summary{cursor:pointer;color:var(--signal);font-size:var(--fs-1);min-height:24px}
.mf-src pre{white-space:pre-wrap;word-break:break-all;margin:6px 0}
.mf-pending{display:inline-block;padding:1px 8px;border-radius:6px;background:var(--control_t,var(--raised));color:var(--ink);font-weight:600}
.mf-target{margin:var(--sp-6) 0}
.apps{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--sp-4);margin-top:var(--sp-4)}
.apps>div{background:var(--surface);border-radius:var(--r);padding:var(--sp-4)}
.apps h3{margin-top:0}.apps .kind{margin-bottom:var(--sp-2)}
@media (max-width:820px){.apps{grid-template-columns:1fr}}
"""


def applications(decision_cycles, period_ns):
    """What HYDRA is good for today (from what is built and checked), and what a smaller process could add (labelled)."""
    dec = (f"one decision takes {decision_cycles} cycles, {decision_cycles * period_ns / 1000:.2f} µs at the tile's "
           f"{1000 / period_ns:.2f} MHz sign-off clock" if decision_cycles and period_ns else "one decision takes a few cycles")
    today = [
        ("A dispatcher beside a few accelerators",
         f"Pick which engine runs each job (a CPU, a vector unit, a systolic array, transform butterflies, a crypto "
         f"slot) from a cost model, refuse engines that cannot do the operation, and correct its own estimates from "
         f"measured run time. On the tile, {dec}, so it suits jobs that run for thousands of cycles: matrix "
         f"multiplies, transforms, hashing."),
        ("Policy you can audit",
         "Security mode and engine policy are checked before cost, with no silent fallback: a job that may not run "
         "anywhere is refused, and the refusal is visible. That fits controllers where which engine touches the data "
         "matters as much as speed."),
        ("Teaching and research in hardware scheduling",
         "Every decision can be replayed cycle by cycle from recorded simulations and the hardened netlist, with "
         "formal proofs on the selector and the interfaces. It is a small, complete, inspectable example of "
         "heterogeneous scheduling in silicon."),
        ("Bring-up and prototyping of accelerator systems",
         "The same dispatcher runs in FPGA images with real engines behind it, so a system's scheduling can be tried "
         "on a board before any silicon (no image has run on a board yet).")]
    later = [
        ("Routing work across CPU, GPU and NPU on a device",
         "With more engine slots and a faster clock, the same eligibility-then-cost decision could route on-device "
         "inference and media work between processors."),
        ("A scheduler that costs almost nothing in area",
         "At a smaller process the dispatcher's logic shrinks while the engines it chooses between grow, so it can "
         "sit beside large accelerators at little area cost."),
        ("Chiplet and offload admission",
         "Deciding which die or offload engine takes a request, under a policy, with measured feedback, is the same "
         "problem at a larger scale."),
        ("Post-quantum crypto engines under policy",
         "The NTT butterflies and the security modes point at lattice-crypto accelerators that must not fall back "
         "silently to a less trusted engine.")]
    card = lambda h, p, k: f'<div><p class="kind">{k}</p><h3>{esc(h)}</h3><p>{esc(p)}</p></div>'
    return ('<div class="wrap apps-wrap"><p class="eyebrow">What it is for</p>'
            '<h2>Where HYDRA fits today, at 130 nm</h2>'
            '<p class="muted">From what is built and checked in this repository.</p>'
            '<div class="apps">' + "".join(card(h, p, "Today") for h, p in today) + '</div>'
            '<h2>On a smaller process</h2>'
            '<p class="muted"><b>Projection, not measured.</b> Nothing below has been built or simulated at another node; '
            'it is where the same design would be most useful if it were.</p>'
            '<div class="apps">' + "".join(card(h, p, "Projection") for h, p in later) + '</div></div>')


def readme_block():
    """The README's table: the headline facts per target, each linked to its command in the fact sheet."""
    T = load()
    if not T:
        return f"{START}\n_The tapeout fact sheet is not generated yet._\n{END}"
    names = ["die width x height", "die area", "process / PDK", "tile pins", "chip I/O (OpenFrame)", "package",
             "signal routing layers used", "I/O pad pitch", "core supply (standard cells VPWR)", "I/O pad supply (VDDIO)",
             "ground (VGND)", "Magic DRC", "LVS errors", "antenna violating nets", "max slew violations, all corners",
             "max fanout violations, all corners"]
    keys = list(T)
    lines = [START, "", "| | " + " | ".join(TITLES.get(k, k) for k in keys) + " |", "|---|" + "---|" * len(keys)]
    for n in names:
        if not any(fact(T[k], n) for k in keys):
            continue
        cells = []
        for k in keys:
            f = fact(T[k], n)
            v = fmt(f) if f else None
            cells.append("—" if f is None else ("pending (padframe DEF not fetched)" if v is None else v))
        lines.append(f"| {n} | " + " | ".join(c.replace("|", "\\|") for c in cells) + " |")
    lines += ["", "Every value is generated by `tools/tapeout_facts.py` into `docs/tapeout/facts.json`, with the command "
              "and source file that reproduce it; the site's [Manufacturing tab]"
              "(https://normansrule.github.io/hydra-skywater130/#manufacturing) shows each one.", "", END]
    return "\n".join(lines)


def main():
    rd = ROOT / "README.md"; s = rd.read_text(); b = readme_block()
    if START not in s:
        sys.exit("atlas_mfg: README.md has no manufacturing markers")
    new = re.sub(re.escape(START) + r".*?" + re.escape(END), lambda m: b, s, flags=re.S)
    if "--check" in sys.argv:
        if new != s:
            sys.exit("readme-manufacturing: README.md's table differs from docs/tapeout/facts.json -- run: python3 tools/atlas_mfg.py")
        print("readme-manufacturing: README table matches docs/tapeout/facts.json")
    else:
        rd.write_text(new); print("atlas_mfg: README manufacturing table written")


if __name__ == "__main__":
    main()
