#!/usr/bin/env bash
#
# doctor.sh -- does this machine have what the build needs?
#
# Run it from anywhere; it does not care what directory you are in:
#
#   ~/src/hydra-skywater130/scripts/doctor.sh
#
# Every tool below is used by some Makefile target. When one is missing the
# failure usually surfaces much later as a confusing error inside a
# simulation or a synthesis script, so this asks the question directly and
# prints the command that fixes it.
#
# Exit status: 0 if everything required is present, 1 otherwise. Optional
# tools are reported but never fail the check.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0; bad=0; warn=0
green() { printf '  \033[32m%-14s\033[0m %s\n' "$1" "$2"; }
red()   { printf '  \033[31m%-14s\033[0m %s\n' "$1" "$2"; }
amber() { printf '  \033[33m%-14s\033[0m %s\n' "$1" "$2"; }

need() {  # need <command> <what it is for> <how to install>
  if command -v "$1" > /dev/null 2>&1; then
    green "$1" "$(eval "${4:-$1 --version}" 2>&1 | head -1 | cut -c1-58)"
    ok=$((ok + 1))
  else
    red "$1" "MISSING -- $2"
    printf '  %-14s install: %s\n' "" "$3"
    bad=$((bad + 1))
  fi
}

want() {  # same, but optional
  if command -v "$1" > /dev/null 2>&1; then
    green "$1" "$(eval "${4:-$1 --version}" 2>&1 | head -1 | cut -c1-58)"
    ok=$((ok + 1))
  else
    amber "$1" "absent -- $2 will not run"
    printf '  %-14s install: %s\n' "" "$3"
    warn=$((warn + 1))
  fi
}

echo
echo "Simulation and conversion"
need sv2v      "every target: SystemVerilog to Verilog" \
               "https://github.com/zachjs/sv2v/releases (put it on PATH)"
need iverilog  "every simulation bench" \
               "sudo apt install iverilog" \
               "iverilog -V"
need python3   "models, generators, tools" \
               "sudo apt install python3"

echo
echo "Synthesis, proof and boards"
need yosys     "area measurement and FPGA synthesis" \
               "sudo apt install yosys"
# sby and yices are REQUIRED: make verify runs 18 proofs, and since
# 2026-10-06 (pipefail) a missing prover fails verify instead of passing it.
need sby       "formal proofs (make padmux, tpu, dma...); make verify fails without it" \
               "sudo apt install yosys-sby  # or: git clone https://github.com/YosysHQ/sby && sudo make -C sby install"
if command -v sby >/dev/null 2>&1 && ! sby --help >/dev/null 2>&1; then
  red "sby" "installed but does not start -- usually a missing Python module:"
  sby --help 2>&1 | tail -1 | sed 's/^/                 /'
  printf '  %-14s install: %s\n' "" "pip install click   # what current sby needs"
  bad=$((bad + 1))
fi
need yices-smt2 "the solver every .sby file names (smtbmc yices)" \
               "sudo apt install yices2  # or build https://github.com/SRI-CSL/yices2"
want nextpnr-ecp5 "FPGA place and route (make fpga)" \
               "sudo apt install nextpnr-ecp5" \
               "nextpnr-ecp5 --version"
want ecppack   "FPGA bitstream packing" \
               "sudo apt install fpga-trellis   # Ubuntu/Debian name for prjtrellis" \
               "ecppack --version"
want openFPGALoader "flashing a board" \
               "sudo apt install openfpgaloader" \
               "openFPGALoader --Version"
want pngquant  "README layout image compression (make render-layout)" \
               "sudo apt install pngquant"
want rsvg-convert "README layout image at web size (make render-layout)" \
               "sudo apt install librsvg2-bin"

echo
echo "Reference PLL calculators -- make verify compares the PLL solver against all"
echo "three and FAILS if any is missing (tools/test_pllcalc.py, deliberately)"
need icepll    "iCE40 PLL reference (icestorm)" \
               "sudo apt install fpga-icestorm"
need ecppll    "ECP5 PLL reference (prjtrellis)" \
               "sudo apt install fpga-trellis   # Ubuntu/Debian name for prjtrellis"
need gowin_pll "Gowin PLL reference (Apicula)" \
               "pip install apycula"

echo
echo "Tile suite"
want cocotb-config "the tile's 18 tests (make tile)" \
               "pip install cocotb" \
               "cocotb-config --version"

echo
echo "Python packages"
for pkg in pytest yaml serial; do
  if python3 -c "import $pkg" 2>/dev/null; then
    green "$pkg" "importable"
    ok=$((ok + 1))
  else
    amber "$pkg" "absent"
    case "$pkg" in
      pytest) printf '  %-14s install: pip install pytest       # make tools\n' "" ;;
      yaml)   printf '  %-14s install: pip install pyyaml       # make bind, boards\n' "" ;;
      serial) printf '  %-14s install: pip install pyserial     # talking to a board\n' "" ;;
    esac
    warn=$((warn + 1))
  fi
done

echo
echo "Repository"
if [[ -f "$ROOT/Makefile" ]]; then
  green "checkout" "$ROOT"
  ok=$((ok + 1))
else
  red "checkout" "no Makefile at $ROOT -- is this the repository?"
  bad=$((bad + 1))
fi

if [[ -f "$ROOT/tt/tile/src/project.v" ]]; then
  green "tile" "submodule present"
  ok=$((ok + 1))
else
  red "tile" "submodule missing -- the tile targets cannot run"
  printf '  %-14s fix: cd %s && git submodule update --init --recursive\n' "" "$ROOT"
  bad=$((bad + 1))
fi

LIB="$ROOT/fpga/vendor_refs/sky130_fd_sc_hd__tt_025C_1v80.lib"
if [[ -f "$LIB" ]]; then
  green "sky130 lib" "$(du -h "$LIB" | cut -f1) -- area measurement ready"
  ok=$((ok + 1))
else
  amber "sky130 lib" "absent -- area measurement will download it on first run"
  printf '  %-14s fetch now: %s/tools/sky130_area.sh\n' "" "$ROOT"
  warn=$((warn + 1))
fi

echo
printf '%d present, %d optional missing, %d required missing\n' "$ok" "$warn" "$bad"
if [[ $bad -gt 0 ]]; then
  echo "Required tools are missing. 'make verify' will not get far."
  exit 1
fi
if [[ $warn -gt 0 ]]; then
  echo "Everything required is here. The optional tools above limit which"
  echo "targets can run; the rest of the suite works."
fi
exit 0
