#!/usr/bin/env bash
# tile-gl.sh -- run the tile's cocotb tests against the HARDENED netlist.
#
# The register-transfer-level suite proves the design. This proves the
# layout implements it: synthesis, buffering, the reset synchroniser and the
# antenna diodes all sit between the two, and only a gate-level run sees them.
#
#   ./scripts/tile-gl.sh                      # uses ~/src/tinytapeout-hydra
#   ./scripts/tile-gl.sh /path/to/hardening-checkout
#
# Unit-delay gate-level simulation of ~24,000 cells is slow: expect minutes.
set -euo pipefail
HC="${1:-$HOME/src/tinytapeout-hydra}"
NET="$HC/runs/wokwi/final/pnl/tt_um_hydra_mom.pnl.v"
[[ -f "$NET" ]] || { echo "tile-gl: no hardened netlist at $NET -- harden first"; exit 2; }

# Find the PDK the run actually used. The 2026-10 runs read it from
# /tmp/pdk/ciel/..., not from a documented location, so search rather than assume.
PRIM=""
for root in "${PDK_ROOT:-}" /tmp/pdk "$HOME/ttsetup/pdk" "$HOME/.ciel" "$HOME/.volare"; do
  [[ -n "$root" && -d "$root" ]] || continue
  PRIM=$(find "$root" -path '*sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v' 2>/dev/null | head -1)
  [[ -n "$PRIM" ]] && break
done
[[ -n "$PRIM" ]] || { echo "tile-gl: sky130A standard-cell models not found; set PDK_ROOT"; exit 2; }
export PDK_ROOT="${PRIM%/sky130A/*}"
echo "tile-gl: netlist  $NET"
echo "tile-gl: PDK_ROOT $PDK_ROOT"

T="$HC/test"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The tests run here must be the VERIFIED tests. Tiny Tapeout's CI runs the
# hardening checkout's test/ folder, so that is the one used -- but only after
# proving it matches tt/tile/test. On 2026-10-06 it did not: an older test.py
# read the status 16 cycles too early and 7 of 17 tests failed on a netlist
# that passes all of them.
stale=0
for f in $(cd "$ROOT/tt/tile" && ls test/*.py test/tb.v test/Makefile 2>/dev/null); do
  if ! cmp -s "$ROOT/tt/tile/$f" "$HC/$f"; then
    echo "tile-gl: $HC/$f differs from the verified tt/tile/$f"; stale=1
  fi
done
if (( stale )); then
  echo "tile-gl: the hardening checkout's tests are stale. Run ./scripts/sync-tile.sh, then this again."
  echo "         (sync-tile also re-copies src/, which is unchanged here, so no re-harden.)"
  exit 2
fi
cp "$NET" "$T/gate_level_netlist.v"
cd "$T" && rm -rf sim_build results.xml
make -s GATES=yes 2>&1 | tee /tmp/tile-gl.log | grep -E "TESTS=|FAIL|PASS=" || true
# Every test the RTL run has, and none failing: the count comes from the log,
# so adding a test does not need an edit here.
if grep -qE "TESTS=([0-9]+) PASS=\1 FAIL=0" /tmp/tile-gl.log; then
  n=$(grep -oE "TESTS=[0-9]+" /tmp/tile-gl.log | tail -1 | cut -d= -f2)
  echo "PASS tile-gl: all $n tile tests pass on the hardened netlist"
else
  echo "FAIL tile-gl: see /tmp/tile-gl.log"; exit 1
fi
