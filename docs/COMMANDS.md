**Every command here assumes a fresh terminal.** Start with
`cd ~/src/hydra-skywater130`, or run `~/src/hydra-skywater130/scripts/doctor.sh`
and `scripts/release.sh` by absolute path from anywhere.

# Command reference

Every command this project needs, in the order you would use them. Run from
the repository root with the virtual environment active unless stated.

## Daily loop

```bash
./scripts/status.sh              # what is set up, what is not, what is next
make verify                      # every check; ~4 minutes
make all                         # TinyTapeout, sky130 and FPGA targets together
```

## Simulation and testbenches

| command | what it runs | typical time |
|---|---|---|
| `make padmux` | pad mux vs its model, plus three proofs | 20 s |
| `make xbar` | crossbar: 20,000 vectors, proofs | 30 s |
| `make system` | dispatcher + crossbar + engines | 40 s |
| `make systile` | the same over the SPI register map | 60 s |
| `make tile` | the tile's 17 cocotb tests | 30 s |
| `make diff` | v2 against v1, 400,000 cycles | 60 s |
| `make harness` | the PC protocol end to end | 60 s |
| `make sky130` | the chip through its pads | 20 s |
| `make tools` | PLL solver and host encodings | 5 s |
| `make tpu` | TPU against its model, plus the port proof | 40 s |
| `make memboard` | whole path over the serial port | 90 s |
| `make dma` | array fed from memory, plus the streamer proof | 40 s |
| `make dma-mutate` | nine breaks in the memory path | ~2 min |
| `make ntt` | butterfly engine vs model, plus proof | 30 s |
| `make ntt-mutate` | nine deliberate breaks | ~2 min |
| `make systile-tpu` | dispatcher + real array, checksums vs the model | 70 s |
| `make tpu-mutate` | nine deliberate TPU breaks, each must be caught | ~3 min |
| `make mutate` | break each behaviour, require its test to fail | ~10 min |

One test on its own:

```bash
cd tt/tile/test && make                          # whole tile suite
cd tt/tile/test && make COCOTB_TESTCASE=test_reg_param_retune_moves_the_decision
sby -f common/formal/mom_xbar.sby prove          # one proof
sby -f common/formal/mom_xbar.sby cover          # its reachability cover
```

Waveforms: every Icarus bench writes `*.vcd` next to itself; open with
`gtkwave tb.vcd`.

## Documentation that is generated

```bash
make isa            # regenerate ISA.md, ISA_CPU.md, ISA_GPU.md from the RTL
make isa-check      # fail if any of them drifts (part of make verify)
python3 tools/isa/gen_cpu_isa.py    # CPU table, by running the decoder
```

## Synthesis, place and route

### FPGA, open toolchain (ECP5, iCE40)

```bash
python3 tools/hydra_bind.py build --plan plans/ecp5-evn.yaml       # tile image
python3 tools/hydra_bind.py build --plan plans/ecp5-evn-sys.yaml   # + engines
python3 tools/hydra_bind.py build --plan plans/ecp5-evn-tpu.yaml   # + real array
make -C fpga/build/ecp5-evn                 # sv2v -> yosys -> nextpnr -> ecppack
make -C fpga/build/ecp5-evn-sys
make -C fpga/build/ecp5-evn-sys provenance  # was this bitstream built from the current sources?
```

A board rebuilds when its sources' CONTENT changes, not their timestamps:
`.srchash` is a hash of every source, and the bitstream records the hash it
was built from. Before 2026-10-06 a rebuild went by timestamps, so an overlay
that left older timestamps on newer sources printed "Nothing to be done" and
kept a stale image. `provenance` exits 1 for a stale or unknown bitstream.

Read the result:

```bash
grep -E "Max frequency|Device utilisation" -A3 fpga/build/ecp5-evn-sys/*.log | tail -20
```

Flash it (ECP5 evaluation board or ULX3S):

```bash
sudo apt-get install -y openfpgaloader
openFPGALoader -b ecp5_evn fpga/build/ecp5-evn-sys/hydra_ecp5_evn_sys.bit
```

### FPGA, vendor toolchains

```bash
python3 tools/hydra_bind.py build --plan plans/arty-a7-35.yaml
cd fpga/build/arty-a7-35 && vivado -mode batch -source build.tcl   # Xilinx
# Intel: the plan emits project.qsf; open it in Quartus or run quartus_sh --flow compile
```

Neither vendor tool is installed here, so those scripts are generated but
unrun. Expect to fix something the first time.

### Synthesis only, for area

```bash
./tools/sky130_area.sh                 # working tree, sky130 cells
./tools/sky130_area.sh HEAD b179c6b    # compare two tile revisions
python3 tools/capacity.py              # which board holds what
yosys -p "read_verilog <file>.v; synth_ecp5 -top <top> -noflatten; stat"   # per module
```

Per-module `stat` is what found the crossbar being 83 times too large. Use it
before believing a utilisation number.

### sky130 hardening (needs LibreLane and the PDK, not installed here)

```bash
# TinyTapeout tile: push and let the action build the GDS
cd tt/tile && git push                 # then read the gds job artifacts
# locally: https://tinytapeout.com/guides/local-hardening/
```

Read `docs/TAPEOUT.md` first: the tile is `tiles: "4x4"` because v2 is 44%
larger than v1, and hand-editing the floorplan is the failure that cost three
weeks on the earlier submission.

## Pushing after each build

The rule: verify, commit, push, and only then start the next block. A red
tree that is also unpushed loses two things at once.

```bash
# 1. before you touch anything: is the tree clean and green?
git status --short && make verify

# 2. after a block is finished, run ITS checks plus the suite
make tpu tpu-mutate          # or padmux / xbar / systile for other blocks
make verify

# 3. commit the block and its verification together, never separately
git add engines/tpu docs Makefile README.md
git commit -m "TPU: output-stationary INT8 array, model-checked and proved

640 results exact against tpu_model.py, port contract proved by induction,
8 of 9 mutations killed (survivor documented in mutate_tpu.py)."
git push

# 4. the tile is its own repository; bump the pointer after pushing it
cd tt/tile && git add -A && git commit -m "..." && git push
cd ../.. && git add tt/tile && git commit -m "bump tile" && git push
```

Before a tapeout submission, tag it so the silicon has a name:

```bash
git tag -a tt-submission-$(date +%Y%m%d) -m "what went to the shuttle"
git push --tags
```

## Pushing

```bash
# main repository
cd ~/src/hydra-skywater130
make verify                                   # do not push red
git add -A && git commit -m "..." && git push

# the tile is a separate repository (submodule)
cd tt/tile
git add -A && git commit -m "Session NNN: ..." && git push
cd ../.. && git add tt/tile && git commit -m "bump tile" && git push
```

If the push is refused over the `workflow` scope:

```bash
gh auth refresh -h github.com -s workflow && git push
```

## Updating from a release zip

```bash
ZIP=$(ls -t /mnt/c/Users/aleks/Downloads/hydra-skywater130-v*.zip | head -1)
rm -rf /tmp/hydra-rel && mkdir -p /tmp/hydra-rel && unzip -q "$ZIP" -d /tmp/hydra-rel
rsync -a --delete --exclude '.git/' --exclude '.gitmodules' --exclude '.venv/' \
  --exclude 'tt/tile/' --exclude 'fpga/vendor_refs/' \
  --exclude 'docs/img/layout.png' --exclude 'fpga/build/*/*.bit' \
  --exclude 'fpga/build/*/*.srchash' --exclude 'fpga/build/*/.srchash' \
  /tmp/hydra-rel/hydra-skywater130/ ~/src/hydra-skywater130/
cd ~/src/hydra-skywater130 && git status --short && make verify
```

Never unzip on top of a git repository: `docs/UPDATING.md` explains why.

| `make release MSG="..."` | verify, then push tile and parent in order | suite + push |
| `make release-dry` | print every command, change nothing | 1 s |
| `make doctor` | does this machine have the tools? | 1 s |
| `make provenance` | which board bitstreams match the current sources | 1 s |
| `make site` | regenerate the project page and diagram | 1 s |
| `make site-check` | the page still matches the repository | 1 s |
