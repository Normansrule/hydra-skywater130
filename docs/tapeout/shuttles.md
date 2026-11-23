# Tapeout beyond Tiny Tapeout

HYDRA-130 has three targets (`THREE_TARGETS.md`). The Tiny Tapeout tile has its
own flow and stays scheduler-only. This page covers the **full chip**: the
scheduler, CPU, TPU and vector engines behind `openframe_project_wrapper` in
`sky130/rtl/hydra_openframe_top.sv`, on a shuttle that takes a whole padframe
user area.

## The framework

| step | what it is | command | evidence today |
|---|---|---|---|
| 1. RTL through the pads | the chip simulated pad by pad, CPU program, UART, LEDs, I2C, SPI | `make sky130-mcu` | in `make verify` |
| 2. Core block harden | `hydra_mcu_core` with its eight SRAM macros, LibreLane | `sky130/harden/mcu_core/config.json` | pnr10: DRC, LVS, antenna 0 |
| 3. Manufacturing facts | die, PDK, pins, layers, voltages, pad pitch, each with its source | `python3 tools/tapeout_facts.py` | `docs/tapeout/facts.json` |
| 4. Shuttle readiness | the chip against each shuttle's harness files | `make shuttle-check` | `docs/tapeout/shuttles.json` |
| 5. Wrapper harden | the core block placed in the shuttle's wrapper, power and pads wired | planned | none |
| 6. Shuttle precheck | the shuttle's own checker on the wrapper GDS | planned | none |
| 7. Gate-level chip simulation | step 1 again on the wrapper netlist | planned | none |

`tools/shuttle_check.py` reads the harness files and prints, per shuttle, each
requirement as PASS, OPEN, PLANNED or BLOCKED with the file or run it came from.

## Shuttles

- **OpenFrame** (ChipFoundry / Efabless, SKY130): the full padframe, 44 GPIO
  pads, no management SoC. This is HYDRA's chip target: `hydra_openframe_top.sv`
  is written as `openframe_project_wrapper`. The check compares its ports with
  Caravel's `def/openframe_project_wrapper.def`, and the core block's size with
  that wrapper's die.
- **Caravel user project** (SKY130): a management SoC and a user area reached
  over Wishbone. HYDRA would need a pin map of its 44 pad functions onto
  Caravel's user I/O, and a Wishbone bridge to the job interface. Planned.
- **GF180MCU, IHP SG13G2**: portability. The RTL has one SKY130-specific cell
  (the SRAM macro behind `SRAM = 1`), and the harden configs name SKY130 cells.
  Planned, after SKY130 is clean.

## What the first run found

`make shuttle-check` on 2026-11-19 found the core block (3200 x 3200 um) wider
than OpenFrame's user area (3166.63 x 4766.63 um in
`openframe_project_wrapper.def`), so it could not be placed in the wrapper.
Core harden 14 reshapes the block to 3000 x 4200 um. The wrapper's 39 port
groups match the harness DEF by name and width; that DEF carries no pin
directions, so directions are not compared.

The harness files come from efabless/caravel at commit 27cbe49, fetched as
`docs/tapeout/README.md` describes.
