# Tapeout-readiness audit

Started 2026-11-15 for two targets: the Tiny Tapeout tile (`tt_um_hydra_mom`)
and the SkyWater 130 OpenFrame microcontroller core (`hydra_mcu_core`). Every
number here comes from a tool run named next to it. The machine-readable facts
(die area, PDK, pins, layers, voltages, extra IP, sign-off counts) are in
`facts.json`, written by `python3 tools/tapeout_facts.py`, where each fact
names its source file and the command that read it.

Labels: **FIXED AND VERIFIED**, **TESTED AND NOT DEFECTIVE**, **DEFERRED WITH
TECHNICAL JUSTIFICATION**, **BLOCKED BY MISSING EVIDENCE**.

## Sign-off

| item | tile (v3.16, run `keep-margin30`) | core (run `pnr9`) | label |
|---|---|---|---|
| route DRC, Magic DRC | 0, 0 | 0, 0 (SRAM interiors read as the PDK's abstract views) | TESTED AND NOT DEFECTIVE |
| LVS, XOR, illegal overlap | 0 | 0 | TESTED AND NOT DEFECTIVE |
| antenna | 0 nets | 0 nets | TESTED AND NOT DEFECTIVE |
| disconnected pins | 0 | 0 (33 before v68; every core input is now read) | FIXED AND VERIFIED |
| setup, every corner | +8.15 ns at 66 ns | +4.25 ns at 70 ns | TESTED AND NOT DEFECTIVE |
| hold, every corner | +0.099 ns | +0.069 ns | TESTED AND NOT DEFECTIVE; the margins are small but positive at every corner |
| gate-level tests | 24 / 24 on the v3.16 netlist | the chip is checked in RTL simulation through its pads; no gate-level simulation of the core | tile TESTED AND NOT DEFECTIVE; core BLOCKED BY MISSING EVIDENCE |
| max slew warnings | 59, slow corners only (1,041 at v3.11, 218 at v3.12) | 12,397 (was 36,436) | open: the rungs and harden 10 below |
| max capacitance warnings | 0 | 167 (was 1,253) | open |
| max fanout warnings | 245 against a limit of 4 | 4,529 against a limit of 6 | open |
| GitHub CI | gds (harden, precheck, gate level), test, docs green at `ef587f1` | verify (all checks, ULX3S build, timing gate, ci_selftest) and mutate green at `f1d5ce2` | FIXED AND VERIFIED |

The tile adopted for the next release is v3.16 (fanout 4, weak and delay buffers excluded, 30% slew repair margin). On the way: v3.13 (fanout 4) 134, v3.14 (stronger buffers) 102; repair at three corners changed nothing, post-route repair gave 111, a 40% margin stalled in repair.

## Pins

| item | evidence | label |
|---|---|---|
| every tile pin has a tested job | v3.11 `PINS` and `GPO` registers; `make tile` and `make tile-gl` test each pin; disconnected pins 0 | TESTED AND NOT DEFECTIVE |
| every chip pad has a job | `docs/pins.md`; v67 puts the CPU's UART on pad 29 and its LEDs on pads 30-43 (I2C `OWNER`); v68 reads the spare inputs in `PINS` (control offset 7); `make sky130-mcu` drives and reads them | FIXED AND VERIFIED |
| package pin numbers | Tiny Tapeout: 64-pin QFN (`tt/docs/PINOUT.md`); OpenFrame: no package chosen | BLOCKED BY MISSING EVIDENCE (OpenFrame) |
| I/O pad pitch | the pad cell is 80.000 um wide (PDK LEF); the padframe's pitch needs Caravel's `def/chip_io.def`, not fetched yet | BLOCKED BY MISSING EVIDENCE |

## Portability to smaller nodes

- The RTL instantiates one process-specific cell, the SRAM macro in
  `sys/rtl/hydra_cpu_sram.sv`, behind `SRAM = 1`; `SRAM_MODEL = 1` is a
  behavioural equivalent for other targets (FPGA, Verilator). Everything else
  is plain SystemVerilog, linted with Verilator `-Wall` at 0 warnings.
- The harden settings name SKY130 cells (`EXTRA_EXCLUDED_CELLS` in the tile's
  `src/config.json` and the core's `config.json`); another PDK needs its own
  list of weak and delay buffers.
- Tiny Tapeout's tooling already carries GF180MCU and IHP SG13G2 technology
  files (`tt/tech/gf180mcuD`, `tt/tech/ihp-sg13g2`). Hardening the tile there
  is the next portability step: **DEFERRED** until the SKY130 warnings are
  closed, so each change has one cause.

## Reference material

`docs/references/README.md` lists the guides used (Tiny Tapeout, SKY130,
Caravel, OpenRAM, LibreLane, OpenROAD, GF180MCU, IHP, Chipyard, FPGA tools).
The course and tapeout material uploaded to the project on 2026-11-15 has not
reached this machine yet: **BLOCKED BY MISSING EVIDENCE**.
