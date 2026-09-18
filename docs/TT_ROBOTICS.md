# The affordable robotics chip: what fits where

Goal, in your words: something like an ESP32 with encryption, multiprocessing
and AI readiness, that talks to sensors quickly and securely, cheap enough to
actually use.

## The uncomfortable arithmetic first

A TinyTapeout tile is 167 x 108 um. The largest common size, `8x2` or `4x4`,
is 0.29 mm2; a four-high `8x4`, where the shuttle allows it, is 0.58 mm2. At
the ~65% density these designs harden at, that is roughly **27,000 or 54,000
standard cells**.

For comparison, measured or from the handoff's place-and-route table:

| block | cells | fits a 4x4 tile alone? |
|---|---|---|
| core_mini (RISC-V) | 9,923 | yes, 37% |
| MOM v2 tile (as built) | 28,183 | no — needs 4x4 at 90%, hence 4x4 was already raised |
| core_pipe | 24,491 | barely |
| tpu_top | 86,591 | no, 3x over |
| ecdsa_top | 188,028 | no, 7x over |

An ESP32 is a ~10 mm2 die on a much smaller process. **The robotics chip you
described does not fit on a TinyTapeout tile and never will.** That is not a
reason to stop using TinyTapeout — it is a reason to be precise about what
each vehicle is for.

## So use each for what it is good at

### TinyTapeout: prove one block per tile, for about $100
Tile 1 exists: the MOM dispatcher, now with its whole interface reachable.
It answers the question no simulation can — does the roofline model, with
calibration, make the right call in silicon at 18 MHz.

**Tile 2, a candidate that does fit**: the secure-sensor front end.

| block | est. cells | why |
|---|---|---|
| core_mini | 9,923 (measured) | runs the loop, executes from external QSPI flash |
| AES-128 | ~12,000 | the encryption in "talks to sensors securely" |
| QSPI execute-in-place | ~4,000 | the TT QSPI Pmod is the standard memory path |
| sensor I/O: SPI master, I2C, 2x PWM, quad encoder | ~6,000 | the actual robot interface |
| **total** | **~32,000** | `4x4` at ~107%: **does not fit as listed** |

Drop the quad encoder and one PWM, or the I2C, and it lands near 27,000 —
which is why this is a budget, not a plan, until `tools/sky130_area.sh` is run
on real RTL. The measurement is two minutes; guessing costs a shuttle slot.

What this tile would demonstrate: a processor that boots from flash, reads a
sensor, encrypts the reading and streams it out, on a $100 tile. That is a
real, citable robotics result, and it is the honest TinyTapeout-sized version
of your goal.

### OpenFrame: the actual robotics chip
15 mm2 and 44 pads, about $14,950 through chipIgnite. This is where the chip
you described lives, and `sky130/rtl/hydra_openframe_top.sv` is already the
wrapper for it, with the tile as its first macro.

A realistic first robotics die, from the blocks that exist:

| block | cells | role in your goal |
|---|---|---|
| core_pipe + core_mini | 34,414 | multiprocessing: control loop and supervisor |
| MOM + crossbar | 36,183 | dispatch across the engines; the novel part |
| tpu_top | 86,591 | AI readiness: INT8 inference |
| AES + HMAC + keystore + SHE CMAC | ~40,000 | encrypted sensor and bus traffic |
| ecdsa_top | 188,028 | signing, attestation — and 55% of the problem |
| axis blocks x 6 | ~18,000 | motors |
| CAN-FD + SecOC | ~21,000 | the vehicle bus, authenticated |
| sensor capture + timestamp | ~4,000 | fusion needs one timebase |
| data RAM | 135,000 | replace with an SRAM macro: 0.93 mm2 of flops today |

At 55% density that is comfortably inside 15 mm2 **if** ECDSA shrinks and the
RAM becomes a macro. Both are already on the handoff's list, and both matter
more for this than any new feature.

### FPGA: where it all runs first
Every block above fits beside the tile on the ECP5 evaluation board, one or
two at a time, which is the loop this project actually runs. See
`docs/CAPACITY.md`.

## The order I would build it in

1. **TRNG** — nothing security-related is real without it, and ECDSA signing
   without one is a nonce accident waiting to happen.
2. **SHE CMAC** — turns the keystore from safe into usable.
3. **Sensor path**: capture with a shared timestamp, then the SPI offload
   port. This is what makes the chip useful to a robot rather than
   interesting to a reviewer.
4. **Motor axes** — replication of already-verified blocks, so cheap per
   axis.
5. **TinyTapeout tile 2** from whatever of 1-3 fits, measured not guessed.
6. **ECDSA shrink**, because it decides the die and the FPGA board.
7. Everything else in `docs/BUILDOUT.md`.
