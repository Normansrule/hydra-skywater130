# Directory guide

The layout of this repository, file by file.

Session 179. Nothing here modifies the HYDRA-130 sources in `~/hydra`. The
only existing code it changes is the TinyTapeout tile, which lives in its own
repository and is referenced here as a submodule; that change ships separately
as `0001-session-179-tile.patch`.

Read `THREE_TARGETS.md` for the plan and the measured numbers, and
`docs/RUNBOOK.md` for the commands.

```
hydra-skywater130/
  Makefile              make verify -- every check below, in order
  THREE_TARGETS.md      the plan and the evidence
  common/               shared RTL used by more than one target
    rtl/hydra_padmux.sv     pad function mux (proved, 8/8 mutations killed)
    rtl/hydra_rst_sync.sv   async assert, sync release, scan bypass
    tb/, formal/            model comparison, proofs, mutation runner
  tt/
    tile/                 the TinyTapeout repo (submodule; session 179 applied)
    rtl/tt_um_hydra_mom_v1.sv   v1 kept as the reference for the diff bench
    tb/tb_v1_v2_diff.sv         v2 legacy vs v1, pin for pin
    formal/                     the SPI target's proof
  fpga/
    rtl/                  UART and the PC bridge harness
    boards/               10 board files, generated from vendor constraint files
    vendor_refs/          those vendor files, with SHA-256 recorded
    build/<board>/        generated top, constraints and build script
    tb_fpga_harness.sv    the PC protocol end to end
  plans/                  one YAML per board build
  tools/
    hydra_bind.py         generate a board top from a plan + the REAL port list
    import_boards.py      build board files from vendor sources; check for drift
    pllcalc.py            PLL settings, never above the requested frequency
    hydra_host.py         drive the tile from a PC over a serial port
    test_*.py             pytest for the two tools above
```

## Quick starts

**Tile, in simulation**

```bash
cd tt/tile/test && make            # 18 tests, the research tile's register map
```

**A board build** (ULX3S shown; swap the plan for another board)

```bash
python3 tools/hydra_bind.py build --plan plans/ulx3s-85f.yaml
cd fpga/build/ulx3s-85f && make            # sv2v -> yosys -> nextpnr -> bitstream
```

Measured on ECP5-85F: 14,360 LUTs (17%), 3,742 flops, Fmax 16.37 MHz, passing
at the requested 12.5 MHz.

**On the bench**

```bash
python3 tools/hydra_host.py --port /dev/ttyUSB0 selftest
```

Runs identity, the roofline crossover, a parameter retune and the calibration
loop over the serial port. Needs `pyserial`.

**Adding a board**

Add a profile to `tools/import_boards.py` naming its vendor constraint file,
run `python3 tools/import_boards.py fetch build`, then write a plan in
`plans/`. The generator refuses a plan that names a port the RTL does not
have, leaves an input undriven, double-books a pin, or drives an input-only
pin.

## What is not here

- Tile area for v2: needs LibreLane and the PDK. Harden before submitting.
- Vivado and Quartus builds: scripts are generated, neither tool is installed
  here, so neither has been run.
- The sky130 full chip: needs the `~/hydra` sources. `THREE_TARGETS.md`
  section 2 has the plan, the area arithmetic, and the frame recommendation.
