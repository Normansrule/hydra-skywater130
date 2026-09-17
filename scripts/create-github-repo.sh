#!/usr/bin/env bash
# =============================================================================
# create-github-repo.sh -- publish this directory as a new public repository
# =============================================================================
#   gh auth login                 (once, interactive)
#   ./scripts/create-github-repo.sh hydra-skywater130
#
# Does nothing clever: initialises git if needed, makes the first commit, then
# `gh repo create --public --push`. If you would rather click through the web
# UI, the manual commands are printed at the end of a failed run.
# =============================================================================
set -euo pipefail
NAME="${1:-hydra-skywater130}"
DESC="${2:-HYDRA-130 build targets: a TinyTapeout tile, a sky130 chip plan, and an FPGA bench platform for the Mathematical Operation MUX}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v gh >/dev/null; then
  cat <<MANUAL
The GitHub CLI is not installed. Either:

  sudo apt-get install -y gh && gh auth login

or create the repository in the browser and push by hand:

  git init -b main
  git add -A && git commit -m "HYDRA-130 targets: TinyTapeout v2, FPGA bench, sky130 plan"
  git remote add origin git@github.com:<you>/$NAME.git
  git push -u origin main
MANUAL
  exit 1
fi

[ -d .git ] || git init -q -b main
git add -A
git diff --cached --quiet || git commit -q -m "HYDRA-130 targets: TinyTapeout v2, FPGA bench platform, sky130 plan"

OWNER="$(gh api user -q .login)"
if gh repo view "$OWNER/$NAME" >/dev/null 2>&1; then
  # Created by an earlier attempt, or by hand. Adopt it rather than failing
  # with "Name already exists on this account".
  echo "$OWNER/$NAME already exists; pushing to it"
  git remote get-url origin >/dev/null 2>&1 \
    || git remote add origin "https://github.com/$OWNER/$NAME.git"
  git push -u origin HEAD
  gh repo edit "$OWNER/$NAME" --visibility public --accept-visibility-change-consequences \
    --description "$DESC" >/dev/null 2>&1 || true
else
  gh repo create "$NAME" --public --source=. --remote=origin --description "$DESC" --push
fi
echo
echo "Published: $(gh repo view --json url -q .url)"
echo "Actions will run make verify on the first push; watch it with: gh run watch"
