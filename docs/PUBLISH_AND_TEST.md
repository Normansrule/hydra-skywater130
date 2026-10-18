# Publish and test: copy-paste commands

Every command starts with `cd`, so it works from any folder in WSL2 Ubuntu.
Each one prints `PASS` lines and fails loudly; none of them changes the
repositories except the publish step at the end.

## Get the latest

```bash
cd ~/src/hydra-skywater130 && git pull && git submodule update --init --recursive
```

## Test

The whole suite: simulations against independent models, formal proofs,
lint, the tile's tests, the generated README figures and site:

```bash
cd ~/src/hydra-skywater130 && make verify
```

The newest pieces on their own:

```bash
cd ~/src/hydra-skywater130 && make abi-v2 systile-abi
```

```bash
cd ~/src/hydra-skywater130 && make gpu systile-gpu select-proof jtag-harness
```

Every deliberate break must be caught (slow):

```bash
cd ~/src/hydra-skywater130 && make mutate && ./scripts/ci_selftest.sh
```

FPGA place and route (ECP5, open toolchain; builds only what changed):

```bash
cd ~/src/hydra-skywater130 && for d in ecp5-evn ecp5-evn-sys ecp5-evn-tpu ecp5-evn-two ecp5-evn-mem ulx3s-85f; do make -C fpga/build/$d || break; done
```

Harden the Tiny Tapeout tile (unattended; runs the gate-level tests, the
slew report and the timing summary when it signs off):

```bash
cd ~/src/hydra-skywater130 && source ~/ttsetup/venv/bin/activate && export PDK_ROOT=$HOME/.ciel && make harden
```

Watch detailed routing while it runs, in a second terminal:

```bash
cd ~/src/hydra-skywater130 && make drt-progress
```

## On a board

ULX3S-85F (the scheduler and its serial bridge), after attaching the board
to WSL with `usbipd` (see `docs/bringup/ulx3s-85f.md`):

```bash
cd ~/src/hydra-skywater130 && openFPGALoader -b ulx3s fpga/build/ulx3s-85f/hydra_ulx3s_tt.bit && python3 tools/hydra_host.py --port /dev/ttyUSB0 id && python3 tools/hydra_host.py --port /dev/ttyUSB0 selftest
```

Basys 3 HYDRA image (needs Vivado):

```bash
cd ~/src/hydra-skywater130/fpga/build/basys3 && vivado -mode batch -source build.tcl && openFPGALoader -b basys3 hydra_basys3_tt.bit
```

## Publish both repositories

Runs `make verify` first and stops if anything fails; then commits and pushes
the tile repository and the parent with the submodule pointer in step:

```bash
cd ~/src/hydra-skywater130 && ./scripts/release.sh -m "what changed and what proves it"
```
