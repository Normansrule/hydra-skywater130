#!/usr/bin/env bash
#
# sync-tile.sh -- put the VERIFIED tile into the checkout you harden from.
#
# WHY THIS EXISTS
#
# The tile lives in two places on your machine:
#
#   ~/src/hydra-skywater130/tt/tile    where `make verify` checks it
#   ~/src/tinytapeout-hydra            where ./tt/tt_tool.py --harden runs
#
# They are separate git checkouts of the same repository, and nothing keeps
# them in step. A harden run on 2026-09-29 failed with repair statistics --
# 2,659 buffers, 306 slew and 476 fanout violations -- IDENTICAL to a failure
# from days earlier. Identical to the buffer. The shared-cost-engine tile,
# 26% smaller, had been verified in one tree and the old tile hardened from
# the other. An evening of place-and-route spent on a design already known
# not to fit.
#
# This copies the tile's submitted files across and then PROVES they match,
# by hash, before you spend another run.
#
#   ./scripts/sync-tile.sh                       default destination
#   ./scripts/sync-tile.sh /path/to/checkout     somewhere else

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/tt/tile"
DST="${1:-$HOME/src/tinytapeout-hydra}"

if [[ ! -f "$DST/info.yaml" ]]; then
  echo "sync-tile: $DST has no info.yaml -- is that the hardening checkout?"
  exit 2
fi

# Refuse to copy a tile that does not pass its own checks. Syncing a broken
# tile is how a broken tile gets hardened.
echo "sync-tile: checking the source tile first"
if ! (cd "$ROOT" && python3 tools/tt_ready.py > /tmp/sync_ready.log 2>&1); then
  tail -15 /tmp/sync_ready.log
  echo "sync-tile: the source tile is NOT ready. Nothing copied."
  exit 1
fi

# Keep a copy of what is about to be replaced, so this is reversible.
BACKUP="/tmp/tinytapeout-hydra-before-sync-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -a "$DST/src" "$DST/info.yaml" "$BACKUP/" 2>/dev/null || true
[[ -d "$DST/docs" ]] && cp -a "$DST/docs" "$BACKUP/"
[[ -d "$DST/test" ]] && cp -a "$DST/test" "$BACKUP/"

# The files the shuttle uses. NOT the tt/ tools directory, NOT runs/, NOT
# .git: only what is submitted and what tests it.
cp -a "$SRC/src/."  "$DST/src/"
cp -a "$SRC/info.yaml" "$DST/info.yaml"
[[ -d "$SRC/docs" ]] && mkdir -p "$DST/docs" && cp -a "$SRC/docs/." "$DST/docs/"
[[ -d "$SRC/test" ]] && mkdir -p "$DST/test" && cp -a "$SRC/test/." "$DST/test/"

# ---- prove it --------------------------------------------------------------
fail=0
# The tests are proved too, not just copied. On 2026-10-06 the gate-level run
# in the hardening checkout failed 7 of 17 tests, each ending exactly 16
# cycles per descriptor early: the SETTLE=4 timing from before the shared
# cost engine, against a netlist that needs 20. Only the design files had
# been compared, so nothing said the tests there were stale.
TEST_FILES=$(cd "$SRC" && ls test/*.py test/tb.v test/Makefile test/requirements.txt 2>/dev/null || true)
for f in src/project.v info.yaml docs/info.md $TEST_FILES; do
  a=$(sha256sum "$SRC/$f" | cut -c1-16)
  b=$(sha256sum "$DST/$f" 2>/dev/null | cut -c1-16 || true); b=${b:-missing}
  if [[ "$a" == "$b" ]]; then
    printf '  match     %-22s %s\n' "$f" "$a"
  else
    printf '  DIFFER    %-22s verified %s  hardening %s\n' "$f" "$a" "$b"
    fail=1
  fi
done

# A fingerprint of the design itself, not just the file: this signal exists
# only in the shared-cost-engine tile. If it is missing, the old design is
# still there regardless of what any hash says.
n=$(grep -c '\blane_we\b' "$DST/src/project.v" || true)
if [[ "$n" -gt 0 ]]; then
  echo "  design    shared cost engine present (lane_we x$n)"
else
  echo "  design    OLD TILE: no shared cost engine in $DST/src/project.v"
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  echo "sync-tile: FAILED. The previous files are in $BACKUP"
  exit 1
fi

echo
echo "sync-tile: $DST now holds the verified tile. Previous files: $BACKUP"
# Say plainly whether the netlist already in runs/ is from this design, so
# nobody runs the gate-level tests against an old one (2026-10-09).
NET="$DST/runs/wokwi/final/pnl/tt_um_hydra_mom.pnl.v"
HARDEN="  cd $DST && source ~/ttsetup/venv/bin/activate && ./tt/tt_tool.py --harden"
if [[ ! -f "$NET" ]]; then
  echo "No hardened netlist yet. Harden, then make tile-gl:"; echo "$HARDEN"
elif python3 "$ROOT/tools/netlist_matches.py" "$NET" "$DST/src/project.v" > /dev/null; then
  echo "The netlist in runs/ matches this design: make tile-gl can run now."
else
  echo "HARDEN NEEDED: the netlist in runs/ is from an older design. Then make tile-gl:"
  echo "$HARDEN"
fi
