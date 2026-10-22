"""
atlas_theme.py -- one palette for every figure and for the project page.

Mask Room. A photolithography room is lit by an amber safelight, because
white light would expose the resist; the mask itself is chrome on quartz.
So the light theme is the room (warm, nearly monochrome, colour kept for
meaning) and the dark theme is the mask. The colours that mean something
are the colours of sky130 mask layers, and each always appears next to a
label and a drawn shape, so colour is never the only cue:

  signal   metal blue        data and requests moving (descriptor, bytes)    ▸
  control  safelight amber   decisions, registers, handshakes, timing       ◆
  compute  metal-2 violet    arithmetic engines (array, vector, butterflies) ■
  memory   diffusion green   scratchpad banks and streamers                 ▤
  secure   polysilicon red   security IP (vault, mailbox, hash, measurement) ◈

DIE is the die view's own palette. A mask is dark in either theme, so the
layout is always drawn on its substrate colour, in the layer colours.

Figures are written once with @token colours (for example fill="@ink") and
emitted twice, NAME.svg (light) and NAME.dark.svg (dark), so a README can
offer both through <picture> and prefers-color-scheme.
"""
import re

LIGHT = {
    # the safelit room: deep amber-filtered paper, ink nearly black-brown; never a white page
    "bg": "#d6c9a3", "surface": "#c9ba90", "raised": "#e2d6b4", "line": "#9e8e62",
    "line2": "#b5a67b", "ink": "#16130b", "ink2": "#352d1d", "dim": "#4a4130",
    "grid": "#16130b",
    "signal": "#18378a", "control": "#653400", "compute": "#5e1f7c", "memory": "#134a27",
    "secure": "#7f1b26", "danger": "#821a0a", "ok": "#134a27",
    "signal_t": "#bcc3d6", "control_t": "#dcbf86", "compute_t": "#ccb8c8", "memory_t": "#b7c6a8",
    "secure_t": "#d8b5a6", "danger_t": "#dcb39f", "neutral_t": "#cbbd94",
    "on_accent": "#fff6e0",
    # categorical, for telling RTL instances apart (never a meaning of its own)
    "cat1": "#18378a", "cat2": "#653400", "cat3": "#5e1f7c", "cat4": "#134a27", "cat5": "#7f1b26",
    "cat6": "#00505a", "cat7": "#4d4500", "cat8": "#72205c", "cat9": "#2c4c0b",
}
DARK = {
    # the mask: chrome on quartz
    "bg": "#0b0c0f", "surface": "#14161b", "raised": "#1c1f26", "line": "#353a45",
    "line2": "#242830", "ink": "#ece9e0", "ink2": "#b4b0a6", "dim": "#918e86",
    "grid": "#ece9e0",
    "signal": "#86a8ff", "control": "#ffc145", "compute": "#d197f2", "memory": "#67cf8b",
    "secure": "#ff8a8a", "danger": "#ff7d66", "ok": "#67cf8b",
    "signal_t": "#18223d", "control_t": "#3a2c0e", "compute_t": "#2d1d3a", "memory_t": "#15301f",
    "secure_t": "#3d1a1d", "danger_t": "#401b14", "neutral_t": "#22252c",
    "on_accent": "#0b0c0f",
    "cat1": "#86a8ff", "cat2": "#ffc145", "cat3": "#d197f2", "cat4": "#67cf8b", "cat5": "#ff8a8a",
    "cat6": "#4fd3d9", "cat7": "#e3d35a", "cat8": "#f08bd0", "cat9": "#a6dc6a",
}
# The die view: substrate and layers, drawn the same in both themes.
DIE = {
    "substrate": "#07080b", "cell": "#13161c", "fill": "#0d0f13",
    "nwell": "#1b2a3a", "diff": "#3a9d5d", "tap": "#2a7a4a", "poly": "#d2493f", "licon": "#e9e3d3",
    "li1": "#8e7fe8", "mcon": "#d9d4c8", "met1": "#4a78e0", "via": "#e3e6ee", "met2": "#b866d9",
    "via2": "#e3e6ee", "met3": "#29aaa3", "via3": "#e3e6ee", "met4": "#cfa73c", "power": "#3a3f4a",
    "lit": "#ffcc45", "lit_core": "#fff4cf", "pick": "#ffffff",
    "ink": "#ece9e0", "ink2": "#b4b0a6",
}
ROLES = ("signal", "control", "compute", "memory", "secure")
SYMBOL = {"signal": "▸", "control": "◆", "compute": "■", "memory": "▤", "secure": "◈"}

FONT = "font-family:'Ubuntu Sans','Ubuntu',ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif"
MONO = "font-family:'Ubuntu Sans Mono','Ubuntu Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"

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
