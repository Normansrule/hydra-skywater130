#!/usr/bin/env bash
# =============================================================================
# setup-tile.sh -- put the TinyTapeout tile sources under tt/tile
# =============================================================================
# The tile is its own repository (a TinyTapeout submission must be standalone),
# so this repository does not copy its RTL. It references it.
#
#   ./scripts/setup-tile.sh                      submodule from the default URL
#   ./scripts/setup-tile.sh --clone              plain clone, no submodule
#   TILE_URL=... ./scripts/setup-tile.sh         use your own fork
#
# Run this after pushing the session-179 commit to the tile repository, so the
# submodule pins a commit that contains v2.
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${TILE_URL:-https://github.com/Normansrule/tinytapeout-hydra.git}"
cd "$ROOT"

if [ -f tt/tile/src/project.v ]; then
  echo "tt/tile is already populated"
  exit 0
fi

# An earlier, half-finished run can leave tt/tile recorded in the index while
# the directory is empty. `git submodule add` then fails with
# "'tt/tile' already exists in the index" and no amount of re-running helps,
# so clear the leftovers first.
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git ls-files --error-unmatch tt/tile >/dev/null 2>&1; then
    echo "clearing a stale tt/tile entry left by an earlier attempt"
    git rm -r --cached -q tt/tile
    git config -f .gitmodules --remove-section "submodule.tt/tile" 2>/dev/null || true
    [ -s .gitmodules ] || rm -f .gitmodules
    rm -rf .git/modules/tt/tile
  fi
fi
# The placeholder README is not a checkout; get it out of the way.
rm -rf tt/tile

if [ "${1:-}" = "--clone" ] || [ ! -d .git ]; then
  git clone "$URL" tt/tile
else
  git submodule add "$URL" tt/tile
  git submodule update --init --recursive
fi

if ! grep -q hydra_tt_regs tt/tile/src/regen.sh; then
  cat <<'WARN'

WARNING: the tile checkout does not contain session 179 (no hydra_tt_regs in
regen.sh). The v2 tests will fail against it. Apply the patch to the tile
repository first:

    cd tt/tile && git am ../0001-session-179-tile.patch && git push

If the tile lives somewhere other than Normansrule/tinytapeout-hydra, point
this script at it:

    rm -rf tt/tile
    TILE_URL=https://github.com/<owner>/tinytapeout-hydra.git ./scripts/setup-tile.sh

WARN
  exit 1
fi
echo "tt/tile ready: $(git -C tt/tile log --oneline -1)"
