# Pushing an update

**Every block below assumes a brand new terminal in no particular
directory.** Each one starts with its own `cd`, so you can paste any single
block without having run the one before it. `REPO` is wherever you cloned
`hydra-skywater130`; the examples use `~/src/hydra-skywater130`.

---

## Starting from nothing

A machine with no checkout at all:

```bash
mkdir -p ~/src && cd ~/src
git clone --recurse-submodules https://github.com/Normansrule/hydra-skywater130.git
cd ~/src/hydra-skywater130
./scripts/doctor.sh            # what is missing, and how to install it
make verify                    # about six minutes
```

Cloned without `--recurse-submodules`? The tile will be an empty directory:

```bash
cd ~/src/hydra-skywater130
git submodule update --init --recursive
```

The tile can also be worked on standalone, which is how Tiny Tapeout hardens
it:

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/Normansrule/tinytapeout-hydra.git
cd ~/src/tinytapeout-hydra
```

Two repositories, one of which is inside the other:

| repository | what it holds |
|---|---|
| `Normansrule/hydra-skywater130` | everything: engines, memory, boards, tools, docs |
| `Normansrule/tinytapeout-hydra` | the tile, as a **submodule** at `tt/tile` |

---

## The one-line version

```bash
cd ~/src/hydra-skywater130
./scripts/release.sh -m "what changed and what proves it"
```

The script works out the repository from its own location, so this is
equally valid from anywhere:

```bash
~/src/hydra-skywater130/scripts/release.sh -m "what changed and what proves it"
```

That runs `make verify`, refuses to push if anything is red, regenerates the
project page, pushes the **tile first**, then the parent with its updated
submodule pointer.

Order matters. Push the parent before the tile and you publish a parent
commit pointing at a tile commit that exists only on your disk: anyone who
clones gets a repository that cannot check out, and you find out days later
on someone else's machine.

Options:

```bash
cd ~/src/hydra-skywater130
./scripts/release.sh -m "..." --dry-run    # print every command, change nothing
./scripts/release.sh -m "..." --quick      # short suite while iterating
./scripts/release.sh -m "..." --tag tt-submission-20260925
```

`--quick` runs `site-check cost-mux tile diff`, about a minute. It is refused
together with `--tag`, because a tag claims a commit was fully verified and
should be able to survive someone checking.

---

## By hand, when you want to see each step

```bash
cd ~/src/hydra-skywater130
make verify                       # never push red

cd ~/src/hydra-skywater130/tt/tile                        # the tile is its own repository
git add -A && git commit -m "..." && git push

cd ~/src/hydra-skywater130        # now the parent, including the pointer
git add -A && git commit -m "..." && git push
```

Check the pointer actually moved:

```bash
cd ~/src/hydra-skywater130
git diff HEAD~1 --submodule=log -- tt/tile
```

If it says nothing, the parent did not record the new tile commit and the two
repositories have silently diverged.

---

## When the push is refused

**Workflow scope.** Changing anything under `.github/workflows/` needs a token
that is allowed to:

```bash
cd ~/src/hydra-skywater130
gh auth refresh -h github.com -s workflow
git push
```

**Submodule not pushed.** "Server does not allow request for unadvertised
object" means the parent points at a tile commit GitHub has never seen. Push
the tile, then the parent.

**Someone else moved first.** `git pull --rebase` in the repository that was
refused, re-run `make verify`, then push. Rebasing does not re-run the tests
for you.

---

## Tagging a submission

```bash
cd ~/src/hydra-skywater130
./scripts/release.sh -m "what went to the shuttle" --tag tt-submission-$(date +%Y%m%d)
```

Tags **both** repositories with the same name. Silicon should always be
traceable to a pair of commits you can check out and re-verify — a tag on the
parent alone leaves the tile ambiguous, which is the part that becomes a chip.

---

## Publishing the project page

`docs/site/index.html` is self-contained: no content delivery network, no
fonts, no build step. GitHub Pages serves it directly.

Once, in the repository's settings:

> Settings → Pages → Source: **Deploy from a branch** → Branch: `main`,
> folder: `/docs`

Then `docs/site/index.html` is live at:

```
https://normansrule.github.io/hydra-skywater130/site/
```

To serve it at the root of the Pages site instead, move the file to
`docs/index.html` and change `SITE` in `tools/gen_site.py` to match — the
generator writes wherever that variable points, and `make site-check` will
tell you if the two disagree.

Check it locally before pushing:

```bash
cd ~/src/hydra-skywater130
make site                                   # regenerate
python3 -m http.server -d docs/site 8000    # then open localhost:8000
```

The page and the architecture diagram are **generated** from
`docs/metrics.json` and the module tree. Never hand-edit them: `make
site-check` runs inside `make verify` and will fail, which is the point.
Edit the numbers in `docs/metrics.json`, or the topology in
`tools/gen_site.py`, and regenerate.

---

## What to do before a shuttle submission

Everything in `docs/FIRST_TRY.md`, then:

```bash
cd ~/src/hydra-skywater130
./scripts/release.sh -m "submission: <what is in it>" \
  --tag tt-submission-$(date +%Y%m%d)
```

Then confirm on GitHub that both repositories show the tag, and that the
parent's `tt/tile` pointer resolves to the tagged tile commit.
