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
| `die.json`, `die.bin` | the tile's routed layout: every placed cell (class, RTL instance as `physical.json` attributes it, cell type, orientation), every routed wire segment and via of every signal net, the power grid, the pins; and each used cell type's own drawing from the PDK's GDS. Packed little-endian arrays, gzip, with the table of contents in the JSON | `tools/atlas_die.py layout` |
| `die-gl.json`, `die-gl.bin` | **Gate-Level Trace**: the value of every one of the layout's nets in every cycle of one dispatch decision, from the tile's own test run on that run's hardened netlist; refused unless the test passes and its pins equal the Recorded RTL Trace of the same test in every cycle of the window | `tools/atlas_die.py gl` |
| `fpga.json` | **Recorded RTL Trace**: the ecp5-evn-mem image's RTL driven through its serial port by `make memboard`: every byte each way, scratchpad writes, the dispatch, engine busy time and the completion; plus that plan's place-and-route numbers from `docs/metrics.json`. A simulation, never shown as a board run | `tools/atlas_fpga.py` (`make atlas-fpga`) |
| `fonts/` | the page's two typefaces, cut to the characters it uses, with their licence | `tools/atlas_fonts.py` |

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
cd ~/src/hydra-skywater130 && make atlas-die RUN=$HOME/src/tinytapeout-hydra/runs/wokwi
```

Extracts that run's routed layout for the die view and records the gate-level decision that lights it (a few
seconds each). `site-check` fails if the recording, the layout and `physical.json` are not from the same netlist,
or if the test, testbench or `project.v` changed after the recording.

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
| Gate-level traces in the player | DEFERRED | the die view replays one decision at gate level, net by net (`die-gl.json`); the player's tabular replays stay RTL traces, because a netlist keeps only pins and some register names, so the player's named signals do not exist in it |
| 3D layout | DEFERRED | the die view draws every layer in 2D, in order; a 3D stack would add depth without adding information |
| Hardware captures | BLOCKED BY MISSING EVIDENCE | no image has run on a board |
