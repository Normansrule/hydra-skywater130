#!/usr/bin/env bash
# =============================================================================
# bootstrap-ubuntu.sh -- every tool this repository's checks need, on a fresh
#                        Ubuntu machine. Safe to run twice.
#
# Developed on 24.04 (noble) and used on 26.04 (resolute). It does not pin a
# release: packages are installed one at a time so a name that has changed in
# your release is reported by name instead of taking the whole install down
# with it.
# =============================================================================
# Installed:
#   apt       git, build-essential, python3-venv, iverilog, verilator, yosys,
#             nextpnr-ice40 + fpga-icestorm, nextpnr-ecp5 + fpga-trellis
#   release   sv2v (zachjs), yices (SRI) -- both from GitHub release assets
#   source    SymbiYosys (sby), which is not packaged for Ubuntu
#   pip       cocotb, pytest, pyyaml, pyserial, apycula (Gowin flow + gowin_pll),
#             click (SymbiYosys needs it)
#
# Python packages go in a virtual environment at .venv unless --system is
# given, because Ubuntu 24.04 refuses pip installs into the system Python.
#
# Usage:  ./scripts/bootstrap-ubuntu.sh [--system] [--no-apt]
# =============================================================================
set -euo pipefail

SYSTEM_PY=0
DO_APT=1
for a in "$@"; do
  case "$a" in
    --system) SYSTEM_PY=1 ;;
    --no-apt) DO_APT=0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

say() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- apt packages
if [ "$DO_APT" -eq 1 ]; then
  . /etc/os-release 2>/dev/null || true
  say "apt packages (${PRETTY_NAME:-unknown release})"
  $SUDO apt-get update -qq
  APT_MISSING=()
  for pkg in git curl unzip build-essential python3 python3-pip python3-venv \
             iverilog verilator yosys \
             nextpnr-ice40 fpga-icestorm nextpnr-ecp5 fpga-trellis; do
    if ! DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
      APT_MISSING+=("$pkg")
    fi
  done
  if [ "${#APT_MISSING[@]}" -ne 0 ]; then
    echo "  these packages did not install: ${APT_MISSING[*]}"
    echo "  (a renamed or dropped package in this release -- check with:"
    echo "   apt-cache search <name>. The version table at the end says what"
    echo "   is actually usable.)"
  fi
fi

# ---------------------------------------------------------------------- sv2v
# The tile's src/regen.sh converts its SystemVerilog with sv2v, and so does
# every FPGA build here. Ubuntu does not package it.
if ! command -v sv2v >/dev/null; then
  say "sv2v"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/sv2v.zip" \
    https://github.com/zachjs/sv2v/releases/latest/download/sv2v-Linux.zip
  unzip -oq "$tmp/sv2v.zip" -d "$tmp"
  $SUDO install -m755 "$tmp"/sv2v-Linux/sv2v /usr/local/bin/sv2v
  rm -rf "$tmp"
fi

# --------------------------------------------------------------------- yices
# The formal proofs run on yices. z3 4.8.12 (the Ubuntu package) hangs on
# these properties -- it sat in "checking assumptions in step 0" for five
# minutes and then died, where yices proves the same thing in under a second.
if ! yices-smt2 --version >/dev/null 2>&1; then
  say "yices"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/yices.tgz" \
    https://github.com/SRI-CSL/yices2/releases/download/Yices-2.6.4/yices-2.6.4-x86_64-pc-linux-gnu.tar.gz
  tar xzf "$tmp/yices.tgz" -C "$tmp"
  $SUDO install -m755 "$tmp"/yices-2.6.4/bin/* /usr/local/bin/
  $SUDO cp -a "$tmp"/yices-2.6.4/lib/* /usr/local/lib/
  $SUDO ldconfig
  rm -rf "$tmp"
fi

# ----------------------------------------------------------------------- sby
if ! command -v sby >/dev/null; then
  say "SymbiYosys"
  tmp="$(mktemp -d)"
  git clone -q --depth 1 https://github.com/YosysHQ/sby.git "$tmp/sby"
  $SUDO make -C "$tmp/sby" install PREFIX=/usr/local >/dev/null
  rm -rf "$tmp"
fi

# -------------------------------------------------------------------- python
say "python packages"
# click: current SymbiYosys imports it. Without it every proof dies at
# startup -- which is how the GitHub runs failed from 2026-10-06, once
# make verify stopped ignoring failed proofs (pipefail).
PKGS="cocotb>=1.8 pytest pyyaml pyserial apycula click"
if [ "$SYSTEM_PY" -eq 1 ]; then
  # shellcheck disable=SC2086
  $SUDO pip install --break-system-packages -q $PKGS
else
  [ -d "$ROOT/.venv" ] || python3 -m venv "$ROOT/.venv"
  # shellcheck disable=SC2086
  "$ROOT/.venv/bin/pip" install -q --upgrade pip $PKGS
  echo "virtual environment: $ROOT/.venv"
  echo "activate it with:    source $ROOT/.venv/bin/activate"
fi

# ------------------------------------------------------------------- report
say "versions"
report() {
  if command -v "$1" >/dev/null; then
    printf '  %-16s %s\n' "$1" "$($2 2>&1 | head -1)"
  else
    printf '  %-16s MISSING\n' "$1"; MISSING=1
  fi
}
MISSING=0
report git          "git --version"
report iverilog     "iverilog -V"
report yosys        "yosys -V"
report sv2v         "sv2v --version"
report sby          "sby --help"
report yices-smt2   "yices-smt2 --version"
report nextpnr-ecp5 "nextpnr-ecp5 --version"
report nextpnr-ice40 "nextpnr-ice40 --version"
report icepll       "echo (icestorm)"
report ecppll       "echo (prjtrellis)"

PY="$ROOT/.venv/bin/python3"
[ "$SYSTEM_PY" -eq 1 ] && PY=python3
if [ -x "$PY" ] || [ "$SYSTEM_PY" -eq 1 ]; then
  $PY - <<'PYEOF' || MISSING=1
import importlib.util, sys
missing = [m for m in ("cocotb", "pytest", "yaml", "serial", "apycula", "click") if not importlib.util.find_spec(m)]
print("  python           " + ("all present" if not missing else "MISSING " + ", ".join(missing)))
sys.exit(1 if missing else 0)
PYEOF
fi

# A present sby that cannot start is worse than a missing one: every proof
# fails, and only in the log does it say why.
if ! sby --help >/dev/null 2>&1; then
  echo
  echo "  sby is installed but does not start:"
  sby --help 2>&1 | tail -2 | sed 's/^/    /'
  MISSING=1
fi

if ! yices-smt2 --version >/dev/null 2>&1; then
  echo
  echo "  yices does not run on this system. The formal proofs need an SMT"
  echo "  solver; z3 from apt hangs on these properties, so build yices from"
  echo "  source instead:"
  echo "    git clone https://github.com/SRI-CSL/yices2 && cd yices2 && \\"
  echo "      autoconf && ./configure && make -j\$(nproc) && sudo make install"
  MISSING=1
fi

if [ "$MISSING" -ne 0 ]; then
  echo
  echo "Something above is missing. Fix it before running make verify:"
  echo "a check that cannot run is not a check that passed."
  exit 1
fi

cat <<EOF

Toolchain ready.

  source .venv/bin/activate      # unless you passed --system
  make verify                    # every check in the repository

Not installed here, and not needed for make verify:
  Vivado / Quartus   vendor FPGA builds (the scripts are generated either way)
  LibreLane + PDK    hardening the TinyTapeout tile; see docs/TAPEOUT.md
EOF
