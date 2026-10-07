# First try: what must be true before anything goes to a shuttle

**Harden the tree you verified.** The tile exists in two checkouts —
`~/src/hydra-skywater130/tt/tile`, where `make verify` checks it, and
`~/src/tinytapeout-hydra`, where hardening runs — and nothing keeps them in
step. On 2026-09-29 a harden run failed with repair statistics identical to
the buffer to a failure days earlier: the old tile had been hardened from the
second checkout. Before every harden run:

```bash
cd ~/src/hydra-skywater130
./scripts/sync-tile.sh
```

It refuses to copy a tile that fails `tt_ready`, copies the submitted files,
and proves by hash and by design fingerprint that the hardening checkout now
holds what was verified.

A tapeout cannot be patched. This is the gate: every line must be green, and
the ones marked **YOU** can only be run on your machine, because they need
tools or a process design kit this repository's build environment does not
have. Nothing here is optional because it was inconvenient.

---

## 1. Downloads and installs (once)

| what | why | how |
|---|---|---|
| Docker | LibreLane hardening runs in a container | `sudo apt install docker.io && sudo usermod -aG docker $USER` then log out and in |
| Python 3.11+ | tt-support-tools requirement | Ubuntu 26.04 ships 3.13; check `python3 --version` |
| tt-support-tools | the Tiny Tapeout hardening driver | cloned into the tile repo, below |
| LibreLane | the open synthesis-to-GDS flow | `pip install librelane==$LIBRELANE_TAG` |
| sky130 PDK | cell libraries, rules, models | fetched automatically on first harden; managed by `ciel` |
| sky130 timing library | the area numbers in section 4 | `tools/sky130_area.sh` downloads it on first run |
| openFPGALoader | flashing the ECP5 board | `sudo apt install openfpgaloader` |
| librsvg2-bin, pngquant | optional: render the die to a picture | `sudo apt install librsvg2-bin pngquant` |

The LibreLane version changes. Before hardening, read the default of the
`librelane-version` input in
<https://github.com/TinyTapeout/tt-gds-action/blob/main/action.yml> and use
that. At the time of writing it is **3.0.3**. A local harden on a different
version than the shuttle's action is a local harden of a different chip.

---

## 2. Everything that runs here, and passed

```bash
cd ~/src/hydra-skywater130
make verify          # every check below, ~6 minutes
make tpu-mutate simd-mutate ntt-mutate dma-mutate   # ~10 minutes
```

| check | result at the time of writing |
|---|---|
| tile cocotb suite, both personalities | 17 / 17 |
| v2 against v1, pin for pin | 400,000 cycles, 3,118 random resets |
| formal proofs | pad mux, reset sync, SPI slave, crossbar, TPU, SIMD, NTT, streamer |
| engines against independent models | TPU 640, SIMD 572, NTT 396 results exact |
| memory path | array 96, vector unit 50 results read back exactly |
| whole path over the serial port | matrices in, 16 results out, all correct |
| mutation suites | TPU 8/9, SIMD 10/10, NTT 8/9, streamer **13/13** — both survivors proven equivalent and documented |

**Mutation scores are only meaningful against a green baseline.** The
streamer's suite now checks its baseline first and refuses to report a score
otherwise, because once a red baseline made every mutation look "killed".

---

## 3. YOU: harden the tile and read the numbers that decide it

```bash
cd ~/src/tinytapeout-hydra
git clone https://github.com/TinyTapeout/tt-support-tools tt   # once

mkdir -p ~/ttsetup
python3 -m venv ~/ttsetup/venv
source ~/ttsetup/venv/bin/activate
pip install -r tt/requirements.txt

export PDK_ROOT=~/ttsetup/pdk
export PDK=sky130A
export LIBRELANE_TAG=3.0.3              # check action.yml first
pip install librelane==$LIBRELANE_TAG

./tt/tt_tool.py --create-user-config     # re-run whenever info.yaml changes
./tt/tt_tool.py --harden                 # needs Docker running
./tt/tt_tool.py --print-warnings         # read every one of them
```

Then print the numbers that decide go or no-go. Metric key names vary by
LibreLane version, so this prints everything relevant rather than guessing
a single key:

```bash
cd ~/src/tinytapeout-hydra
python3 - <<'PY'
import json, glob
f = sorted(glob.glob("runs/wokwi/final/metrics.json"))[-1]
m = json.load(open(f))
for k in sorted(m):
    if any(w in k for w in ("timing__setup__ws", "timing__hold__ws",
                            "route__drc_errors", "magic__drc_error",
                            "klayout__drc_error", "design__lvs_error",
                            "antenna", "design__instance__utilization",
                            "design__max_slew_violation", "design__max_cap_violation")):
        print(f"{k:70s} {m[k]}")
PY
```

**Go only if:**

| metric | required |
|---|---|
| every `timing__setup__ws` (all corners, including `nom_ss_100C_1v60`) | ≥ 0 |
| every `timing__hold__ws` | ≥ 0 |
| DRC errors (route, magic, klayout) | 0 |
| LVS errors | 0 |
| antenna violations | 0, or each one understood |
| max slew / max capacitance violations | 0 |
| utilisation | under about 70% for a 4×4 tile — v2 measured 67.5% by synthesis |

The slow-corner setup slack was open from session 139 to 2026-10-02, and the
lesson is worth keeping: it did not close when the clock was lengthened from
55 to 66 ns, because the failing checks started at the reset PIN, not in the
cost model's multipliers. It closed (+2.184 ns) once the reset was released
through a synchroniser. If a longer clock barely moves the slack, run
`tools/critical_paths.py` before changing anything else.

---

## 4. YOU: gate-level simulation against the hardened netlist

**Done 2026-10-07: 17 / 17.** Rerun after any re-harden. If it fails, first
check `tile-gl` did not stop on stale tests (run `./scripts/sync-tile.sh`).

```bash
cd ~/src/hydra-skywater130 && make tile-gl
```
`scripts/tile-gl.sh` copies `runs/wokwi/final/pnl/tt_um_hydra_mom.pnl.v` into the
test directory, finds the sky130 cell models wherever the harden left them
(the 2026-10 runs used `/tmp/pdk/ciel/...`), and runs all 17 tests with
`GATES=yes`. It prints `PASS tile-gl` only on 17/17.

The register-transfer level suite passing proves the design. The same suite
passing against the **hardened netlist** proves synthesis did not change it.
Different things; both are required.

```bash
cd ~/src/tinytapeout-hydra/test
pip install -r requirements.txt
TOP_MODULE=$(cd .. && ./tt/tt_tool.py --print-top-module)
cp ../runs/wokwi/final/pnl/$TOP_MODULE.pnl.v gate_level_netlist.v
make -B GATES=yes
```

Required: **17 / 17**, the same as at register-transfer level.

If it fails with a missing `primitives.v`, the PDK is not enabled:

```bash
source ~/ttsetup/venv/bin/activate
ciel ls                 # copy the hash of the installed PDK
ciel enable <hash>
```

---

## 5. YOU: the last engine area number

Measured on 2026-10-06 with `make area-ntt`: the butterfly engine is 8,551
cells / 70,524 µm² at q=12289 and 7,079 cells / 57,763 µm² at q=3329 (both in
`docs/CAPACITY.md`). The ML-DSA modulus did not finish in that run; its 46-bit
products make it the slowest by far. Run it alone and leave it:

```bash
cd ~/src/hydra-skywater130
QS=8380417 make area-ntt          # prints progress, then one "ntt q=8380417" line
```

Send that line back and it goes into the capacity table.

These are synthesis estimates, not place-and-route results. They rank blocks
and catch order-of-magnitude surprises; the hardened number is the one that
counts.

---

## 6. YOU: the board, before the shuttle

The FPGA is the cheapest place to find a system-level fault. Every image
below passed place-and-route here; none has touched real hardware yet.

```bash
cd ~/src/hydra-skywater130
make fpga                                   # builds all ECP5 images
openFPGALoader -b ecp5_evn fpga/build/ecp5-evn-mem/hydra_ecp5_evn_mem.bit
python3 tools/hydra_host.py --port /dev/ttyUSB1 selftest
```

Check the FTDI channel-B jumpers against the board user guide first — the
serial pins are on that header. The serial port is usually the SECOND device
the FTDI chip creates; try `ttyUSB1` before `ttyUSB0`.

What a pass looks like on the board: identity reads `48594D32`, a matrix
loaded with `load_gemm` and dispatched comes back matching NumPy, and the
tile counter on the lights (both switches up) increments once per dispatch.

---

## 7. Pushing, after each green step

```bash
cd ~/src/hydra-skywater130
make verify && git add -A && git commit -m "..." && git push
cd tt/tile && git add -A && git commit -m "..." && git push
cd ../.. && git add tt/tile && git commit -m "bump tile" && git push
git tag -a tt-submission-$(date +%Y%m%d) -m "what went to the shuttle" && git push --tags
```

Tag the exact commit that is submitted. The silicon should always be
traceable to a commit you can check out and re-verify.
