# The Silicon Atlas: data, tools and deployment

The atlas is the project page, `docs/site/index.html`: one self-contained file with no network access, the same
from disk and from GitHub Pages. Everything on it is generated from this folder and the repository's sources.

## One source per kind of fact

| file | holds | written by |
|---|---|---|
| `atlas.yaml` | blocks, their logical positions and connections, the builds to derive, the traces to record | hand, reviewed |
| `cards.yaml` | each block's job, ports, clock and reset, example, failure behaviour, evidence and file:line citations, plus the documents-versus-RTL disagreements | hand, from the RTL |
| `derived.json` | per build, every elaborated instance and module and the sha256 of each source; per file, the commit for its permalink | `tools/atlas_derive.py` |
| `traces/*.json` | recorded runs of passing tests: signals per cycle, events, command, commits, tool versions, source hashes | `tools/atlas_traces.py` |
| `physical.json` | the tile's placed cells, each attributed to an RTL instance only by netlist names | `tools/atlas_physical.py` |
| `flow.json` | one harden, step by step, with the facts its own logs state | `tools/atlas_flow.py` |

Numbers on the page come from these files, `docs/metrics.json` and `docs/timing.json`. Pins and registers are read
from `tt/tile/info.yaml` and the tile's RTL by `tools/atlas_tile.py` each time the page is built.

## Commands

```bash
cd ~/src/hydra-skywater130 && make atlas
```

Re-derives every build from its own make target or plan (compile steps only), re-records every trace (each test
must pass, or the tool refuses), and rebuilds the page.

```bash
cd ~/src/hydra-skywater130 && make atlas-physical RUN=$HOME/src/tinytapeout-hydra/runs/wokwi LADDER=<ladder run id> && make atlas-flow RUN=$HOME/src/tinytapeout-hydra/runs/ladder-previous-<id> LABEL="tile vX, ladder run <id>"
```

Maps a finished harden (refused unless its netlist was built from the current `tt/tile/src/project.v`) and
summarises its steps. The page names the run and says whether `docs/timing.json` records it.

```bash
cd ~/src/hydra-skywater130 && make site-check
```

Fails if the page differs from what the generator would write now, or if any derived file, trace or layout map is
older than the sources it describes. `make verify` runs it.

`docs/site/media/` holds two short WebM films with WebVTT captions and posters (the dispatch decision and the
systolic array), drawn from the same traces by `tools/gen_readme_gifs.py`; `make readme-check` compares their
frame hashes, because video encoders are not byte-reproducible. They never play on their own.

## Deployment

`.github/workflows/pages.yml` runs `gen_site.py --check` on every push that touches the page or its data and then
serves `docs/site/` as it is. It needs one setting, made once by the owner: Settings, Pages, Build and deployment,
Source: GitHub Actions. Until then the deploy job fails and nothing else is affected. The Tiny Tapeout repository's
Pages slot is used by Tiny Tapeout's own GDS viewer (its `gds.yaml`), so the tile's atlas lives here, on the tile tab.

## Labels

Every replay names what it is: **Recorded RTL Trace** (a value change dump of a passing RTL simulation),
**Gate-Level Trace** (the same, on a hardened netlist), **Model Simulation** (an executable model checked against
the RTL), **Hardware Capture** (measured on a board or chip), **Concept** (an explanation, not evidence) and
**Recorded Tool Output** (logs and reports of one identified tool run). Motion between two recorded samples is
presentation; the cycle counter shows only recorded cycles.

## Not done, and why

| item | status | reason |
|---|---|---|
| Gate-level traces | DEFERRED | a hardened netlist keeps only pins and some register names, so a gate-level replay can show pins, not the decision inside; it should be recorded from the release harden, compared pin for pin with the RTL trace of the same test. The gate-level test results themselves are in `make tile-gl` |
| 3D layout | DEFERRED | the layout data has cell positions only, no metal layers; a 2D view shows all of it |
| Hardware captures | BLOCKED BY MISSING EVIDENCE | no image has run on a board |
