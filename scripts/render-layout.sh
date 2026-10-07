#!/usr/bin/env bash
# render-layout.sh -- render the hardened tile and put the picture where both
# READMEs expect it (docs/img/layout.png and tt/tile/docs/img/layout.png).
# tt_ready refuses to pass while a README points at an image that is missing,
# so this must run before release.sh once the READMEs show the layout.
#
# The README copy is web-sized. tt_tool's own gds_render.png is full
# resolution: 42 MB on 2026-10-01, which would sit in git history for good and
# make both README pages slow to open. This renders WIDTH pixels wide (default
# 1600), compresses with pngquant when it is installed, and refuses anything
# over 5 MB -- the same limit tt_ready checks.
set -euo pipefail
HC="${1:-$HOME/src/tinytapeout-hydra}"
WIDTH="${WIDTH:-1600}"
MAX_BYTES=$((5 * 1024 * 1024))
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$HC"
./tt/tt_tool.py --create-png

OUT="$TMP/layout.png"
if [[ -f gds_render_preview.svg ]] && command -v rsvg-convert >/dev/null; then
  rsvg-convert -w "$WIDTH" gds_render_preview.svg -o "$OUT"
  echo "render-layout: rendered gds_render_preview.svg at ${WIDTH} px"
else
  SRC=""
  for f in gds_render_preview.png gds_render.png; do [[ -f "$f" ]] && { SRC="$f"; break; }; done
  [[ -n "$SRC" ]] || { echo "render-layout: tt_tool produced no image (looked for gds_render*.png/.svg in $HC)"; exit 2; }
  if command -v convert >/dev/null; then
    convert "$SRC" -resize "${WIDTH}x>" "$OUT"
  elif python3 -c "import PIL" 2>/dev/null; then
    python3 - "$SRC" "$OUT" "$WIDTH" <<'EOF'
import sys
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
src, out, w = sys.argv[1], sys.argv[2], int(sys.argv[3])
im = Image.open(src)
if im.width > w:
    im = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)
im.save(out, optimize=True)
EOF
  else
    echo "render-layout: need one of rsvg-convert (sudo apt install librsvg2-bin), ImageMagick, or Pillow to size the image"; exit 2
  fi
  echo "render-layout: scaled $SRC to ${WIDTH} px"
fi

if command -v pngquant >/dev/null; then
  pngquant --force --skip-if-larger --quality 60-90 --output "$TMP/q.png" "$OUT" && mv "$TMP/q.png" "$OUT" || true
else
  echo "render-layout: pngquant not installed (sudo apt install pngquant) -- image left uncompressed"
fi

BYTES=$(stat -c %s "$OUT")
if (( BYTES > MAX_BYTES )); then
  echo "render-layout: $((BYTES / 1024)) KB is over the 5 MB limit; try WIDTH=1200 $0, or install pngquant"; exit 1
fi
mkdir -p "$ROOT/docs/img" "$ROOT/tt/tile/docs/img"
cp "$OUT" "$ROOT/docs/img/layout.png"
cp "$OUT" "$ROOT/tt/tile/docs/img/layout.png"
echo "render-layout: $((BYTES / 1024)) KB -> docs/img/layout.png and tt/tile/docs/img/layout.png"
