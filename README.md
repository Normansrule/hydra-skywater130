# HYDRA-130 targets

Three build targets for the **Mathematical Operation MUX (MOM)**: a hardware
dispatcher that decides, in three cycles, which of five compute engines should
execute a unit of work — scalar CPU, SIMD, TPU systolic array, number-theoretic
transform (NTT), or crypto — using a roofline cost model that corrects itself
from measured completion times.

| target | what it is | state |
|---|---|---|
| **TinyTapeout tile** | the MOM on sky130 silicon, now with its whole interface reachable over SPI | built and verified in simulation; not yet hardened |
| **sky130 full chip** | the MOM plus the engines on an OpenFrame padframe | wrapper, pad plan and chip-level test running; one macro in it so far |
| **FPGA** | the same RTL on any board, driven from a PC over USB serial | placed, routed and bitstreamed on ECP5 |

`docs/RUNBOOK.md` is the copy-paste command list from a bare machine to a
published repository, including what to do when a step fails. `THREE_TARGETS.md` is the long version: the plan, every measured number, and —
just as important — what was **not** measured.

## Why this exists

An analytical cost model is cheap and always wrong. The MOM watches what
actually happened and corrects the model, in hardware, with no software
involvement. Two claims follow from that, and neither can be settled in
simulation alone:

1. the dispatch policy can be **retuned after tapeout**;
2. the calibration loop **converges against real latencies**.

The tile's first version could not test either, because 24 pins were not enough
to reach the parameter write port or the calibration controls. This repository
adds a second personality that reaches all of it, and an FPGA platform where
the loop runs against real elapsed time rather than a testbench's fixed delays.

Measured with that register interface, in simulation:

- raising the TPU's modelled setup cost from 64 to 4000 cycles moves an 8×8×8
  INT8 matrix multiply from the TPU to the SIMD unit, and a lock bit makes the
  same write inert;
- with completions arriving far later than predicted, the decision margin falls
  from 136 to 1 over 18 dispatches, and the 19th picks a different engine.

## Quick start (Ubuntu 24.04)

```bash
git clone --recurse-submodules https://github.com/<you>/hydra-skywater130.git
cd hydra-skywater130
./scripts/bootstrap-ubuntu.sh          # iverilog, yosys, nextpnr, sv2v, sby, yices, cocotb
source .venv/bin/activate
./scripts/setup-tile.sh                # only if you cloned without submodules
python3 tools/import_boards.py fetch   # board pin files, from the vendors
make verify
```

`make all` builds all three targets from the one source: the TinyTapeout tile
(tests plus cell area), the sky130 chip (the OpenFrame wrapper driven through
its pads), and the FPGA bitstream. `docs/CAPACITY.md` says which board holds
which expansion.

`make verify` runs, in order: the pad mux against an independent model plus its
proofs, the tile's 17 cocotb tests across both personalities, a pin-for-pin
comparison of the new tile against the old one over 400,000 cycles, the PC
protocol end to end, the phase-locked loop (PLL) solver against the vendors'
own calculators, and two drift checks.

`make mutate` is the slow one: it breaks each behaviour on purpose and requires
the test named for it to fail.

## Build for a board

```bash
python3 tools/hydra_bind.py build --plan plans/ulx3s-85f.yaml
cd fpga/build/ulx3s-85f && make        # sv2v -> yosys -> nextpnr -> bitstream
```

Recommended board: the **Lattice ECP5 Evaluation Board (LFE5UM5G-85F-EVN)**,
in stock at DigiKey, fully open toolchain. Measured for this design on that
board: 14,360 lookup tables of 83,640 (17%), 3,742 flip-flops, maximum
frequency 31.85 MHz, passing at the board's 12 MHz oscillator. The same design needs
8,622 4-input lookup tables on iCE40, so it does **not** fit an iCEBreaker —
an ECP5 is the smallest open-toolchain board that can host it.

Ten boards are described: Arty A7-35 and A7-100, Basys 3, Nexys A7-100T, Nexys
Video, Genesys 2, iCEBreaker, ULX3S, Tang Nano 20K, DE10-Lite. Each board file
is generated from that vendor's own constraint file, with its URL and SHA-256
recorded, because a pin table typed from memory is a copy that nothing keeps
honest.

## Drive it from a PC

```bash
python3 tools/hydra_host.py --port /dev/ttyUSB0 selftest
```

Identity, the roofline crossover, a parameter retune, and the calibration loop —
over the board's USB serial port, using the same register map the simulation
tests use.

## How this is verified

Four rules, inherited from the parent project:

1. **Formal properties with mutations that must die.** A proof that cannot fail
   proves nothing, so each one is attacked. 16 of 16 formal mutations are
   killed; 14 of 15 simulation sabotages are caught by the test named for each,
   and the survivor is documented as unobservable at the pins rather than
   quietly deleted.
2. **Testbenches against an independent model**, written from the specification
   rather than from the RTL.
3. **End-to-end through the real interface** — the tile's pins, and the PC
   protocol.
4. **Headers that explain why**, including what went wrong and how it was
   found. The headers are the project's memory.

No test is ever weakened to make it pass.

## Layout

```
common/     RTL used by more than one target, with its proofs
tt/         the TinyTapeout tile (submodule), its v1 reference, its benches
fpga/       UART bridge harness, board descriptions, generated builds
plans/      one YAML per board build
tools/      generators and their tests; the PC host script
docs/       CAPACITY (what fits where), BUILDOUT (the sixteen expansions),
            TT_ROBOTICS (which vehicle for which goal), TAPEOUT, RUNBOOK
scripts/    bootstrap, tile setup, repository creation
```

Licensed under Apache 2.0. See `NOTICE` for the board-file provenance.
