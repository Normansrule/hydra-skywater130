# ULX3S-85F bring-up: the scheduler image on a physical board

**Status: PROCEDURE. Not yet run.** No physical-board result exists for any
HYDRA image. The CI place-and-route of this plan (run 38013429983,
2026-10-10) predates the baud-rate fix, and a CI artifact is not a board
result. Fill in the record below from a real run, or leave it blank.

## What the image contains

The Tiny Tapeout scheduler (cost model, calibration, SPI register map), the
serial bridge and nothing else: no engines and no security mode.

- Plan: `plans/ulx3s-85f.yaml`.
- Clock: 25 MHz oscillator, PLL to 12.5 MHz.
- Serial: 115200 baud, 8N1. The divisor is generated as 109 clocks per bit.
  The bit period is 8.720 µs against an ideal 8.681 µs (−0.45 %).

## 1. Build the exact revision

```bash
cd ~/src/hydra-skywater130 && git rev-parse HEAD && python3 tools/hydra_bind.py build --plan plans/ulx3s-85f.yaml && make -C fpga/build/ulx3s-85f 2>&1 | tee fpga/build/ulx3s-85f/pnr.log && make -C fpga/build/ulx3s-85f provenance && cat fpga/build/ulx3s-85f/hydra_ulx3s_tt.bit.manifest
```

The build fails if timing does not close, because nextpnr runs without
`--timing-allow-fail`. Keep `pnr.log` and the `.manifest`.

## 2. Program and identify

```bash
cd ~/src/hydra-skywater130 && openFPGALoader -b ulx3s fpga/build/ulx3s-85f/hydra_ulx3s_tt.bit && python3 tools/hydra_host.py --port /dev/ttyUSB0 id
```

Expected: `ID 0x48594d32 (HYM2 ok)`.

## 3. Measure the serial bit period

Put an oscilloscope or logic analyser on the FTDI receive line (board to PC)
during the `id` reply. Measure ten bit times on a `0x55` byte. The expected
value is 87.2 µs, and anything within ±2 % (85.5 to 88.9 µs) passes. Record
the instrument and its sample rate.

## 4. Functional tests

```bash
cd ~/src/hydra-skywater130 && python3 tools/hydra_host.py --port /dev/ttyUSB0 selftest 2>&1 | tee ulx3s-selftest.log && python3 tools/hydra_host.py --port /dev/ttyUSB0 calibrate --slow-us 200 -n 60 2>&1 | tee ulx3s-calibrate.log
```

`selftest` checks the roofline crossover, a parameter retune that moves the
decision, and the calibration loop closing, with the same expectations as
the simulation.

## 5. Record (leave blank until measured)

| item | value |
|---|---|
| repository revision | |
| image SHA-256 (from the manifest) | |
| tools (from the manifest) | |
| nextpnr Fmax and slack (from `pnr.log`) | |
| utilisation (LUT4, flip-flops, EBR) | |
| board revision (silkscreen) | |
| host OS, Python, pyserial | |
| measured 10-bit time | |
| `id` output | |
| `selftest` result | |
| `calibrate` result | |
| date and operator | |

Commit the logs under `reports/<revision>/ulx3s-85f/`. Until this table is
filled from a real run, the capability matrix stays at "placed and routed".
