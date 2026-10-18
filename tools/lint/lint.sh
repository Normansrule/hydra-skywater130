#!/bin/bash
# lint.sh -- Verilator --lint-only -Wall on what gets hardened, with the
# settings LibreLane's linter uses (DECLFILENAME and EOFNEWLINE off).
#
#   1. the Tiny Tapeout tile's submitted netlist, tt/tile/src/project.v,
#      exactly as LibreLane lints it: no waivers;
#   2. the SkyWater OpenFrame chip, generated the same way (sv2v, then the
#      unused-constant filter), with the waivers in tools/lint/waivers.vlt.
#
# Fails on any warning. The FPGA images are built by Yosys and are not
# covered here.
set -euo pipefail
cd "$(dirname "$0")/../.."
T="${SIMTMP:-$(mktemp -d)}"
mkdir -p "$T"
V=(verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-EOFNEWLINE)
fail=0

run() {  # label, top, files...
  local label=$1 top=$2; shift 2
  local log="$T/lint_$label.log"
  if "${V[@]}" --top-module "$top" "$@" >"$log" 2>&1 && ! grep -q '^%' "$log"; then
    echo "  clean  $label ($top)"
  else
    echo "  FAIL   $label ($top): $(grep -c '^%Warning' "$log" || true) warnings, log $log"
    grep '^%' "$log" | head -20
    fail=1
  fi
}

run tile tt_um_hydra_mom tt/tile/src/project.v

sv2v mom/rtl/*.sv mom/hydra_mom_pins.sv common/rtl/hydra_rst_sync.sv \
     common/rtl/hydra_padmux.sv sky130/rtl/hydra_openframe_top.sv |
  python3 tools/lint/sv2v_clean.py > "$T/openframe_lint.v"
run openframe openframe_project_wrapper tools/lint/waivers.vlt "$T/openframe_lint.v"

if [ $fail -ne 0 ]; then echo "FAIL lint"; exit 1; fi
echo "PASS lint: tile netlist and OpenFrame chip are Verilator -Wall clean"
