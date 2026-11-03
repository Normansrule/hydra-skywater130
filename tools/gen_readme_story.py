#!/usr/bin/env python3
"""
gen_readme_story.py -- the atlas's opening story as an animated WebP for the READMEs.

A README cannot run WebGL, so this films the page itself: docs/site/index.html in
a headless Chromium (tools/atlas_shots.mjs), one frame per scroll position from the
whole tile down to one flip-flop, through the exploded layer stack and back out.
Every frame is the page drawing the hardened tile's own layout and the gate-level
recording; the camera is moved straight to where its spring is heading, which is
the frame a reader sees once the motion settles.

    python3 tools/gen_readme_story.py      writes docs/img/story.webp (and the tile's copy)

WebP rather than GIF: the layout's layer colours need more than 256 colours per frame,
and an animated WebP of the same frames is a quarter of the size.

Like the screenshots, this is a picture of the page, not evidence, and readme-check
does not compare it (a browser renders fonts slightly differently per machine).
"""
import glob, json, os, pathlib, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTS = [ROOT / "docs/img/story.webp", ROOT / "tt/tile/docs/img/story.webp"]
W, H, OUT_W = 1280, 800, 900
# scroll positions in viewport heights, and how long each frame holds (ms)
STOPS = ([(0.0, 1400)] + [(0.2 * i, 140) for i in range(1, 5)] + [(1.0, 1200)]
         + [(1.0 + 0.2 * i, 140) for i in range(1, 5)] + [(2.0, 1400)]
         + [(2.0 + 0.25 * i, 160) for i in range(1, 4)] + [(3.0, 1100)]
         + [(3.0 + 0.2 * i, 140) for i in range(1, 5)] + [(4.0, 1600)]
         + [(4.0 + 0.125 * i, 130) for i in range(1, 8)] + [(5.0, 900)]
         + [(5.0 + 0.2 * i, 140) for i in range(1, 5)] + [(6.0, 2600)])
# settle the camera, then step the recording one cycle back and forth so the sparks of the nets that change
# are on screen, and hold their clock still while the frame is taken
SETTLE = ("setTimeout(()=>{const v=document.getElementById('die-hero')._die;if(v){Object.assign(v.cam,v.tgt);"
          "v.v={x:0,y:0,l:0,tilt:0,yaw:0};v.kick();const c=v.cycle;if(c!=null){v.setCycle(c>4380?c-1:c+1);"
          "setTimeout(()=>{v.setCycle(c);v.freezeT=v.spLast+0.3;v.kick()},200)}}},1600)")


def chrome():
    c = os.environ.get("CHROME_PATH")
    if c:
        return c
    found = sorted(glob.glob(os.path.expanduser("~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome")))
    if not found:
        raise SystemExit("gen_readme_story: no Chromium; set CHROME_PATH")
    return found[-1]


def site_button():
    """The README's 'View the full site' button, drawn in the atlas palette (light and dark)."""
    import sys
    sys.path.insert(0, str(ROOT / "tools"))
    import atlas_theme as T
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="560" height="84" viewBox="0 0 560 84" role="img" '
           'aria-label="View the full site: the Silicon Atlas">'
           '<style>@keyframes s{0%{transform:translateX(-140px)}60%,100%{transform:translateX(620px)}}'
           '.g{animation:s 3.2s cubic-bezier(.23,1,.32,1) infinite}@media (prefers-reduced-motion:reduce){.g{animation:none;opacity:0}}</style>'
           '<defs><clipPath id="c"><rect x="2" y="2" width="556" height="80" rx="40"/></clipPath></defs>'
           '<rect x="2" y="2" width="556" height="80" rx="40" fill="@control"/>'
           '<g clip-path="url(#c)"><rect class="g" x="0" y="0" width="70" height="84" fill="@on_accent" opacity=".18" transform="skewX(-20)"/></g>'
           '<g transform="translate(40 26)" fill="none" stroke="@on_accent" stroke-width="3">'
           '<path d="M16 0v32M0 16h32"/><rect x="6" y="6" width="20" height="20"/></g>'
           '<text x="94" y="52" style="font-family:\'Ubuntu Sans\',ui-sans-serif,system-ui,sans-serif;font-size:27px;font-weight:700" '
           'fill="@on_accent">View the full site</text>'
           '<text x="350" y="52" style="font-family:\'Ubuntu Sans\',ui-sans-serif,system-ui,sans-serif;font-size:18px" '
           'fill="@on_accent" opacity=".85">Silicon Atlas →</text></svg>')
    for name, text in T.variants("site_button.svg", svg):
        for d in (ROOT / "docs/img", ROOT / "tt/tile/docs/img"):
            (d / name).write_text(text)
    print("  docs/img/site_button.svg and .dark.svg")


def main():
    from PIL import Image
    with tempfile.TemporaryDirectory() as tmp:
        jobs = [{"out": f"{tmp}/f{i:03d}.png", "hash": "overview", "width": W, "height": H, "dark": True,
                 "scroll": s, "load": 4500, "wait": 2400, "eval": SETTLE} for i, (s, _) in enumerate(STOPS)]
        jf = pathlib.Path(tmp) / "jobs.json"
        jf.write_text(json.dumps({"chrome": chrome(), "url": (ROOT / "docs/site/index.html").as_uri(), "jobs": jobs}))
        subprocess.run(["node", str(ROOT / "tools/atlas_shots.mjs"), str(jf)], check=True, capture_output=True)
        frames = []
        for i in range(len(STOPS)):
            im = Image.open(f"{tmp}/f{i:03d}.png").convert("RGB").resize((OUT_W, round(H * OUT_W / W)), Image.LANCZOS)
            frames.append(im)
        # ffmpeg's libwebp_anim encoder, each frame held for its own time
        lst = []
        for i, (im, (_, d)) in enumerate(zip(frames, STOPS)):
            im.save(f"{tmp}/s{i:03d}.png")
            lst.append(f"file '{tmp}/s{i:03d}.png'\nduration {d / 1000:.3f}")
        lst.append(f"file '{tmp}/s{len(frames) - 1:03d}.png'")
        (pathlib.Path(tmp) / "list.txt").write_text("\n".join(lst) + "\n")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", f"{tmp}/list.txt",
                        "-c:v", "libwebp_anim", "-lossless", "0", "-q:v", "70", "-compression_level", "6", "-loop", "0",
                        "-vsync", "vfr", f"{tmp}/story.webp"], check=True)
        data = (pathlib.Path(tmp) / "story.webp").read_bytes()
        for out in OUTS:
            out.write_bytes(data)
            print(f"  {out.relative_to(ROOT)}  {len(data) // 1024} KiB, {len(frames)} frames")


if __name__ == "__main__":
    import sys
    site_button()
    if "--button" not in sys.argv:
        main()
