#!/usr/bin/env bash
# =============================================================================
# sky130_area.sh -- standard-cell area of the tile, before committing to a harden
# =============================================================================
# WHY: the only way to know whether a tile size is big enough is to harden it,
# and a harden takes an hour. Mapping to the sky130 cells with yosys+abc takes
# two minutes and gets you close enough to choose `tiles:` with confidence.
#
# WHAT THIS IS NOT: an OpenLane result. OpenLane uses a different synthesis
# strategy and then adds buffering, clock tree and fill, so the absolute number
# here reads LOW. Trust the RATIO between two designs, not the absolute value,
# and confirm with a real harden before submitting.
#
# Usage:  ./tools/sky130_area.sh [git-ref ...]     (default: the working tree)
#         ./tools/sky130_area.sh HEAD b179c6b      (compare v2 against v1)
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${SKY130_LIB:-$ROOT/fpga/vendor_refs/sky130_fd_sc_hd__tt_025C_1v80.lib}"
TILE="$ROOT/tt/tile"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$LIB" ]; then
  echo "fetching the sky130 timing library (13 MB, once)"
  mkdir -p "$(dirname "$LIB")"
  curl -fsSL -o "$LIB" "https://raw.githubusercontent.com/efabless/skywater-pdk-libs-sky130_fd_sc_hd/master/timing/sky130_fd_sc_hd__tt_025C_1v80.lib"
fi

# A tile is 167 x 108 um; `tiles: WxH` in info.yaml buys W*H of them.
python3 - "$@" <<'PY' > "$WORK/sizes.txt"
print("tile budgets (167 x 108 um each):")
for w, h in ((1,1),(2,2),(3,4),(4,4),(8,2),(6,4),(8,4)):
    print(f"  {w}x{h}: {w*167*h*108:8.0f} um2")
PY
cat "$WORK/sizes.txt"

measure() {  # $1 = label, $2 = project.v path
  yosys -q -l "$WORK/$1.log" -p "
    read_verilog $2
    hierarchy -top tt_um_hydra_mom
    synth -top tt_um_hydra_mom -flatten
    dfflibmap -liberty $LIB
    abc -liberty $LIB
    opt_clean -purge
    stat -liberty $LIB" || { echo "$1: yosys failed"; return 1; }
  area=$(grep -oP "Chip area for module .*: \K[\d.]+" "$WORK/$1.log" | tail -1)
  cells=$(grep -oP "Number of cells: *\K\d+" "$WORK/$1.log" | tail -1)
  printf '%-12s %10.0f um2   %6s cells\n' "$1" "$area" "$cells"
}

echo
if [ "$#" -eq 0 ]; then
  measure "worktree" "$TILE/src/project.v"
else
  for ref in "$@"; do
    git -C "$TILE" show "$ref:src/project.v" > "$WORK/$ref.v"
    measure "$ref" "$WORK/$ref.v"
  done
fi
echo
echo "Density = area / tile budget. v1 hardened at 3x4, which put it near 62%."
