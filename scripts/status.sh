#!/usr/bin/env bash
# =============================================================================
# status.sh -- what is done, what is not, and the next command to run
# =============================================================================
# Run it from anywhere inside the repository. It changes nothing.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
no()   { printf '  \033[31m[no]\033[0m   %s\n' "$1"; NEXT="${NEXT:-${2:-}}"; }
info() { printf '         %s\n' "$*"; }

echo
echo "repository: $ROOT"
. /etc/os-release 2>/dev/null && info "${PRETTY_NAME:-unknown release}"
echo
echo "toolchain"
MISS=""
for t in git sv2v yosys iverilog sby yices-smt2 nextpnr-ecp5; do
  if command -v "$t" >/dev/null; then ok "$t"; else no "$t" "./scripts/bootstrap-ubuntu.sh"; MISS="$MISS $t"; fi
done
if python3 -c "import cocotb, yaml, pytest" 2>/dev/null; then
  ok "python packages (cocotb, yaml, pytest)"
else
  no "python packages -- is the virtual environment active?" "source .venv/bin/activate"
  info "source $ROOT/.venv/bin/activate    (or re-run scripts/bootstrap-ubuntu.sh)"
fi
[ -n "${CONDA_DEFAULT_ENV:-}" ] && info "note: conda '$CONDA_DEFAULT_ENV' is active; 'conda deactivate' first if python misbehaves"

echo
echo "tile"
if [ -f tt/tile/src/project.v ]; then
  ok "tt/tile is populated"
  if grep -q hydra_tt_regs tt/tile/src/regen.sh 2>/dev/null; then
    ok "tt/tile contains session 179"
  else
    no "tt/tile does NOT contain session 179" "apply 0001-session-179-tile.patch to the tile, push, then rm -rf tt/tile && ./scripts/setup-tile.sh"
  fi
  info "remote: $(git -C tt/tile remote get-url origin 2>/dev/null || echo none)"
  info "head:   $(git -C tt/tile log --oneline -1 2>/dev/null || echo unknown)"
else
  if git ls-files --error-unmatch tt/tile >/dev/null 2>&1; then
    no "tt/tile is empty but recorded in the index (half-finished submodule add)" \
       "./scripts/setup-tile.sh   # it clears the stale entry itself"
  else
    no "tt/tile is empty" "./scripts/setup-tile.sh"
  fi
fi

echo
echo "inputs"
if [ -f fpga/vendor_refs/icebreaker.pcf ]; then ok "vendor pin files fetched"
else no "vendor pin files missing" "python3 tools/import_boards.py fetch"; fi

echo
echo "publication"
if [ -d .git ]; then
  ok "git repository initialised"
  R="$(git remote get-url origin 2>/dev/null || true)"
  if [ -n "$R" ]; then ok "remote: $R"
    if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
      ok "pushed: $(git log --oneline -1)"
    else no "not pushed yet" "git push -u origin main"; fi
  else no "no remote yet" "./scripts/create-github-repo.sh hydra-skywater130"; fi
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    info "signed in to GitHub as $(gh api user -q .login 2>/dev/null)"
  fi
else
  no "not a git repository yet" "git init -b main"
fi

echo
echo "builds"
for d in fpga/build/*/; do
  b="$(basename "$d")"
  if ls "$d"*.bit "$d"*.bin "$d"*.fs >/dev/null 2>&1; then ok "$b: bitstream built"
  elif ls "$d"*.sv >/dev/null 2>&1; then info "$b: top and constraints generated, not built"
  fi
done

echo
if [ -n "${NEXT:-}" ]; then
  echo "next:  $NEXT"
else
  echo "next:  make verify"
fi
echo
