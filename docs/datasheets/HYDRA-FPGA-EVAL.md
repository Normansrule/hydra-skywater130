# HYDRA-FPGA-EVAL: FPGA evaluation images

**PRELIMINARY EVALUATION SPECIFICATION, revision 0.1 (2026-10-11).** None of
these images has run on a physical board. The serial and clock values below
are design values checked in simulation, not measurements.

## Images

| image | board | contents | clock | serial divisor (clocks per bit) |
|---|---|---|---|---|
| `ulx3s-85f` | ULX3S, ECP5-85F | scheduler + bridge | 12.5 MHz (PLL from 25 MHz) | 109 (−0.45 %) |
| `ecp5-evn` | ECP5 evaluation board | scheduler + bridge | 12 MHz | 104 (+0.16 %) |
| `ecp5-evn-sys` | ECP5 evaluation board | scheduler + five latency models | 12 MHz | 104 |
| `ecp5-evn-tpu` | ECP5 evaluation board | scheduler + 4×4 array on generated patterns | 12 MHz | 104 |
| `ecp5-evn-two` | ECP5 evaluation board | scheduler + array + vector unit on patterns | 12 MHz | 104 |
| `ecp5-evn-mem` | ECP5 evaluation board | scheduler + memory-fed array; host loads and reads banks | 12 MHz | 104 |
| `arty-a7-35` | Arty A7-35T | scheduler + bridge | 25 MHz | 217 (+0.01 %) |
| `tangnano20k` | Tang Nano 20K | scheduler + bridge | 27 MHz | 234 (+0.16 %) |
| Basys 3 self-test | Basys 3 | display and serial self-test, **no HYDRA logic** | 100 MHz | 868 (fixed in its source, not generated) |

Each divisor is generated from the plan's clock by `tools/hydra_bind.py`,
must be within a 2 % error budget, and is checked against an independently
timed host at −2 %, 0 and +2 % (`make uart-baud`).

## Host protocol (serial, 8N1, 115200)

| command | reply |
|---|---|
| `A5 n d…` SPI frame to the register map | `5A n r…` |
| `C3 m` reset the tile | `3C m` |
| `4D b ah al d3 d2 d1 d0` write a bank word (`ecp5-evn-mem` only) | `B2 s`: s = 00 written, **01 refused because an engine owns the bank** |
| `52 ah al` read a result word (`ecp5-evn-mem` only) | `A6 d3 d2 d1 d0` (undefined while a job runs) |
| `4D` or `52` on an image with no scratchpad | `EE 4D` / `EE 52`, like any unknown command |

## Memory-fed engines (`ecp5-evn-mem`; the vector unit and NTT in simulation)

- **Ownership.** From the cycle an engine accepts a job until it reports
  completion, it owns all its banks. Host writes in that window are refused
  and reported.
- **Completion.** Done means every result is in the result bank.
- **Refusals.** Status 2 means wrong data type, 3 bad dimensions, and 4 a
  job that would run past the end of a bank. Nothing is read or written, and
  the engine is ready for the next job.
- **NTT memory format v1.** One residue per 32-bit word. Operands sit at
  `group*4 + lane` and results at `group*8 + 2*lane (+1)`. A load whose value
  is ≥ q is refused.

## Build gates

- nextpnr runs without `--timing-allow-fail`. Vivado stops on negative setup
  or hold slack.
- Each bitstream has a `.manifest` with the image hash, the source and
  constraint hashes, and tool versions.
- A constraint-only change rebuilds the image.

## Not provided

FHE, SE, any CPU, any GPU, DDR, utilisation and timing for every image except
`ulx3s-85f` (from CI), and every physical-board measurement.
