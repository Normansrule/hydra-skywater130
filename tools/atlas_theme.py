"""
atlas_theme.py -- one palette for every figure and for the project page.

Graphite and ivory, with four signal colours that each mean one thing, and
always appear next to a label and a symbol so colour is never the only cue:

  signal   cyan    data and requests moving (descriptor, bytes, operands)   ▸
  control  amber   decisions, registers, handshakes, timing               ◆
  compute  violet  arithmetic engines (array, vector unit, butterflies)   ■
  memory   teal    scratchpad banks and streamers                         ▤
  secure   rose    security IP (vault, mailbox, hash, measurement)        ◈

Figures are written once with @token colours (for example fill="@ink") and
emitted twice, NAME.svg (ivory, light) and NAME.dark.svg (graphite), so a
README can offer both through <picture> and prefers-color-scheme. A figure
shown through <img> cannot see the page's theme; two files can be chosen by it.
"""
import re

LIGHT = {
    "bg": "#f4f1e8", "surface": "#fbf9f3", "raised": "#ffffff", "line": "#d6cfbf",
    "line2": "#e6e0d3", "ink": "#1c1d21", "ink2": "#4b4d55", "dim": "#6b6d74",
    "grid": "#1c1d21",
    "signal": "#0a7488", "control": "#9a5300", "compute": "#6a3fcf", "memory": "#0b7a5c",
    "secure": "#ad2f57", "danger": "#b42318", "ok": "#0b7a5c",
    "signal_t": "#d9eef2", "control_t": "#f6e6cf", "compute_t": "#e8e0f8", "memory_t": "#d6efe5",
    "secure_t": "#f6dde5", "danger_t": "#f7dcd8", "neutral_t": "#ebe6da",
    "on_accent": "#ffffff",
    # categorical, for telling RTL instances apart on the layout (never a meaning of its own)
    "cat1": "#0a7488", "cat2": "#9a5300", "cat3": "#6a3fcf", "cat4": "#0b7a5c", "cat5": "#ad2f57",
    "cat6": "#3d5fc4", "cat7": "#7a6a00", "cat8": "#a0379a", "cat9": "#2f7d32",
}
DARK = {
    "bg": "#121417", "surface": "#181b20", "raised": "#20242b", "line": "#363c47",
    "line2": "#2a2f38", "ink": "#ece8de", "ink2": "#b9b5ab", "dim": "#8d8b85",
    "grid": "#ece8de",
    "signal": "#4cc6de", "control": "#efac46", "compute": "#ac8ef6", "memory": "#47c49c",
    "secure": "#ef7fa0", "danger": "#f27a6e", "ok": "#47c49c",
    "signal_t": "#17323a", "control_t": "#3a2b14", "compute_t": "#2a2140", "memory_t": "#163329",
    "secure_t": "#3c1d28", "danger_t": "#3e1d1a", "neutral_t": "#262a31",
    "on_accent": "#121417",
    "cat1": "#4cc6de", "cat2": "#efac46", "cat3": "#ac8ef6", "cat4": "#47c49c", "cat5": "#ef7fa0",
    "cat6": "#7d9bff", "cat7": "#d8cb52", "cat8": "#e08ad9", "cat9": "#8fd36b",
}
ROLES = ("signal", "control", "compute", "memory", "secure")
SYMBOL = {"signal": "▸", "control": "◆", "compute": "■", "memory": "▤", "secure": "◈"}

FONT = "font-family:'IBM Plex Sans','Inter',ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif"
MONO = "font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"

TOKEN = re.compile(r"@([a-z][a-z0-9_]*)")


def paint(svg, mode):
    """Replace every @token with the colour for `mode` ('light' or 'dark')."""
    pal = LIGHT if mode == "light" else DARK

    def sub(m):
        k = m.group(1)
        if k in ("keyframes", "media", "supports", "font", "import"):
            return m.group(0)                 # CSS at-rules inside the figure's <style>
        if k not in pal:
            raise KeyError(f"atlas_theme: unknown colour token @{k}")
        return pal[k]
    return TOKEN.sub(sub, svg)


def css_vars(pal):
    return ";".join(f"--{k.replace('_', '-')}:{v}" for k, v in pal.items())


def variants(name, svg):
    """[(file name, svg text)] for the light and the dark version."""
    stem = name[:-4] if name.endswith(".svg") else name
    return [(f"{stem}.svg", paint(svg, "light")), (f"{stem}.dark.svg", paint(svg, "dark"))]


def picture(path, alt, width="100%"):
    """README markup that shows the variant matching the reader's theme."""
    dark = path[:-4] + ".dark.svg"
    return (f'<picture>\n  <source media="(prefers-color-scheme: dark)" srcset="{dark}">\n'
            f'  <img src="{path}" width="{width}" alt="{alt}">\n</picture>')
