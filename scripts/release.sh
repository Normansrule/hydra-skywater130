#!/usr/bin/env bash
#
# release.sh -- push a big update to both repositories, in the right order,
# and only if the suite is green.
#
# WHY A SCRIPT AND NOT A LIST OF COMMANDS
#
# Two things go wrong when this is done by hand:
#
#   1. The tile is a SUBMODULE. Pushing the parent without pushing the tile
#      first produces a parent commit pointing at a tile commit that exists
#      only on your disk. Anyone who clones it gets a repository that cannot
#      check out, and the failure appears days later on someone else's
#      machine.
#
#   2. "I'll just push this and run the tests after." The tests are the only
#      reason to believe any of this works. This script runs them first and
#      refuses to push if they fail.
#
# USAGE
#
#   ./scripts/release.sh -m "what changed and what proves it"
#   ./scripts/release.sh -m "..." --tag tt-submission-20260925
#   ./scripts/release.sh -m "..." --dry-run      # print, change nothing
#   ./scripts/release.sh -m "..." --quick        # short suite, see below
#
# --quick runs the checks that catch most regressions in about a minute
# instead of the full suite. Use it while iterating; do NOT use it for a
# tapeout tag, which is what --tag is for and which always runs everything.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TILE="$ROOT/tt/tile"

MSG=""
TAG=""
DRY=0
QUICK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message) MSG="$2"; shift 2 ;;
    --tag)        TAG="$2"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --quick)      QUICK=1; shift ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "release.sh: unknown argument '$1'"; exit 2 ;;
  esac
done

if [[ -z "$MSG" ]]; then
  echo "release.sh: a commit message is required (-m \"...\")."
  echo "Say what changed AND what proves it -- future you reads these."
  exit 2
fi

run() {
  if [[ $DRY -eq 1 ]]; then
    echo "    would run: $*"
  else
    "$@"
  fi
}

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Can each repository actually be pushed? Checked BEFORE the suite.
#
# A submodule is checked out at a commit, not on a branch ("detached HEAD").
# On 2026-10-06 this script committed the tile there, `git push` refused
# ("You are not currently on a branch"), and the run stopped half done. This
# works out where each repository pushes to, and that the push will be a
# fast-forward, before anything is committed.
# ---------------------------------------------------------------------------
push_target() {   # push_target <repo> -> sets BR (remote branch) or exits
  local repo="$1" name="$2" cur
  git -C "$repo" fetch -q origin || { echo "release.sh: cannot fetch $name from origin"; exit 1; }
  BR=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
  BR=${BR:-main}
  git -C "$repo" rev-parse -q --verify "origin/$BR" >/dev/null || {
    echo "release.sh: $name has no origin/$BR to push to"; exit 1; }
  cur=$(git -C "$repo" symbolic-ref -q --short HEAD || true)
  if [[ -n "$cur" && "$cur" != "$BR" ]]; then
    echo "release.sh: $name is on branch '$cur', but origin's default branch is '$BR'."
    echo "  Switch to $BR, or push $cur by hand. Nothing has been changed."; exit 1
  fi
  if ! git -C "$repo" merge-base --is-ancestor "origin/$BR" HEAD; then
    echo "release.sh: $name has diverged from origin/$BR -- the push would not be a fast-forward."
    echo "  git -C $repo log --oneline --graph HEAD origin/$BR -10   # see both sides"
    echo "  Nothing has been changed."; exit 1
  fi
  if [[ -z "$cur" ]]; then
    echo "    $name: detached HEAD (normal for a submodule); will push HEAD to origin/$BR"
  else
    echo "    $name: on $cur; will push to origin/$BR"
  fi
}

# Files over 5 MB are refused. Published history keeps every version of a
# file for good: on 2026-10-07 the tile's history turned out to hold a 42 MB
# and a 6.8 MB render of the layout, committed by runs of this script before
# render-layout.sh learned to make a web-sized copy.
MAX_BYTES=$((5 * 1024 * 1024))
too_big() {   # too_big <repo> <name>: list files `git add -A` would take that exceed the limit
  local repo="$1" name="$2" f bad=0
  while IFS= read -r -d '' f; do
    [[ -f "$repo/$f" ]] || continue
    if (( $(stat -c %s "$repo/$f") > MAX_BYTES )); then
      echo "release.sh: $name/$f is $(( $(stat -c %s "$repo/$f") / 1024 / 1024 )) MB (limit 5 MB)"; bad=1
    fi
  done < <(git -C "$repo" ls-files -z -m -o --exclude-standard)
  return $bad
}

say "0/5  Push targets"
TILE_IS_REPO=0
if [[ -d "$TILE/.git" ]] || [[ -f "$TILE/.git" ]]; then
  TILE_IS_REPO=1
  push_target "$TILE" "tile (tt/tile)"; TILE_BR="$BR"
fi
push_target "$ROOT" "parent"; ROOT_BR="$BR"
big=0
[[ $TILE_IS_REPO -eq 1 ]] && { too_big "$TILE" "tt/tile" || big=1; }
too_big "$ROOT" "." || big=1
if (( big )); then
  echo "  Shrink it (a layout image: ./scripts/render-layout.sh), or add it to .gitignore."
  echo "  Nothing has been changed."; exit 1
fi

# ---------------------------------------------------------------------------
# 1. Green before anything else
# ---------------------------------------------------------------------------
if [[ -n "$TAG" && $QUICK -eq 1 ]]; then
  echo "release.sh: --quick and --tag together is not allowed. A tag is a"
  echo "claim that a specific commit was fully verified; prove it."
  exit 2
fi

if [[ $QUICK -eq 1 ]]; then
  TARGETS="site-check cost-mux tile diff"
  say "1/5  Short suite ($TARGETS)"
else
  TARGETS="verify"
  say "1/5  Full suite (make verify)"
fi

if [[ $DRY -eq 1 ]]; then
  echo "    would run: make -C $ROOT $TARGETS"
else
  if ! make -C "$ROOT" $TARGETS; then
    echo
    echo "release.sh: the suite is RED. Nothing has been committed or pushed."
    echo "Fix it, or if the failure is expected, say so in the commit message"
    echo "and push by hand -- this script will not do it for you."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 2. The page and diagram are generated: make sure what ships is current
# ---------------------------------------------------------------------------
say "2/5  Regenerating the project page and architecture diagram"
run make -C "$ROOT" site

# ---------------------------------------------------------------------------
# 3. The tile first, because the parent points at it
# ---------------------------------------------------------------------------
say "3/5  Tile repository (submodule)"
if [[ $TILE_IS_REPO -eq 1 ]]; then
  if [[ -n "$(git -C "$TILE" status --porcelain)" ]]; then
    run git -C "$TILE" add -A
    run git -C "$TILE" commit -m "$MSG"
  fi
  # Push whenever HEAD is not yet on origin -- including a commit left by an
  # earlier run that failed to push. Skipping it because the working tree is
  # clean would publish a parent that points at a tile commit nobody can fetch.
  if [[ $DRY -eq 1 ]] || ! git -C "$TILE" merge-base --is-ancestor HEAD "origin/$TILE_BR"; then
    run git -C "$TILE" push origin "HEAD:refs/heads/$TILE_BR"
  else
    echo "    tile already on origin/$TILE_BR, nothing to push"
  fi
else
  echo "    no tile checkout here -- run scripts/setup-tile.sh first"
fi

# ---------------------------------------------------------------------------
# 4. Then the parent, including the new submodule pointer
# ---------------------------------------------------------------------------
say "4/5  Parent repository"
run git -C "$ROOT" add -A
if [[ $DRY -eq 1 ]] || ! git -C "$ROOT" diff --cached --quiet; then
  run git -C "$ROOT" commit -m "$MSG"
else
  echo "    parent: nothing new to commit"
fi
run git -C "$ROOT" push origin "HEAD:refs/heads/$ROOT_BR"

# ---------------------------------------------------------------------------
# 5. Tag, if this is a submission
# ---------------------------------------------------------------------------
if [[ -n "$TAG" ]]; then
  say "5/5  Tagging $TAG"
  run git -C "$ROOT" tag -a "$TAG" -m "$MSG"
  run git -C "$ROOT" push --tags
  if [[ $TILE_IS_REPO -eq 1 ]]; then
    run git -C "$TILE" tag -a "$TAG" -m "$MSG"
    run git -C "$TILE" push origin "$TAG"
  fi
  echo
  echo "Tagged in BOTH repositories. Silicon should always be traceable to a"
  echo "pair of commits you can check out and re-verify."
else
  say "5/5  No tag requested"
fi

say "Done"
if [[ $DRY -eq 1 ]]; then
  echo "This was a dry run. Nothing changed."
fi
