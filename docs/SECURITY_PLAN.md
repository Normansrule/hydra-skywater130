# Security architecture: what to build, and what not to claim

This is a plan, not a status report. Everything here is unbuilt unless it
says otherwise, and the sections that say a thing is infeasible mean it.

---

## What Caliptra actually is

[Caliptra](https://github.com/chipsalliance/Caliptra) (CHIPS Alliance,
Apache-2.0) is a **Root of Trust for Measurement** for datacenter-class
systems-on-chip. It gives the chip around it three things: **identity**,
**measured boot**, and **attestation**. It is not a general cryptographic
accelerator for applications, and it is not a privacy engine.

Its parts live in separate repositories: `caliptra-rtl` holds the immutable
hardware, `caliptra-sw` the read-only memory image, first-mutable code and
runtime, `adams-bridge` the post-quantum accelerator, `caliptra-ss` a
subsystem with a manufacturer control unit, and `caliptra-dpe` an
implementation of the Trusted Computing Group's DICE Protection Environment.

Version 2.x signs firmware with **ML-DSA**, adds Open Compute Project
recovery, and offloads crypto through the mailbox. Version 2.1 adds
**ML-KEM** and an AES direct-memory-access mode.

### What to take from it, and what not to

**Take the pattern.** Four ideas carry over to a small chip and cost little:

1. **An immutable boot stage.** A read-only memory that cannot be changed
   after manufacture measures the next stage before running it. Everything
   else rests on this.
2. **A mailbox, not a bus.** The root of trust exposes a narrow command
   interface instead of sharing memory with the application cores. A narrow
   interface is one you can actually reason about.
3. **A key vault the processor cannot read.** Keys move between engines by
   slot number. Software asks for a signature, never for the key.
4. **Measurement registers that only extend.** A register that can be
   written to an arbitrary value proves nothing.

**Do not take the block.** The Caliptra core contains a VeeR EL2 RISC-V
processor, SHA-512, ECDSA-384, HMAC, a key vault and a mailbox. That is
orders of magnitude larger than a Tiny Tapeout tile — the whole HYDRA tile
is 144,505 µm² of standard cells. Copying the architecture is sensible;
claiming to have integrated Caliptra would be false.

---

## Fully homomorphic encryption: the honest assessment

**Fully homomorphic encryption will not run on this chip, and saying it does
would be a lie.** The numbers are not close:

| what a scheme needs | what exists here |
|---|---|
| Polynomial degree 4096 to 32768 | four butterflies, no polynomial storage |
| Coefficient moduli of 30 to 60 bits, several at once | one modulus, 23 bits at the largest |
| Tens of megabytes of ciphertext in flight | 1024 words of scratchpad |
| Tens of gigabytes per second of memory bandwidth | one 32-bit word per cycle |
| Key switching and relinearisation | not built |

A single homomorphic multiply on a small parameter set moves more data than
this scratchpad holds, many times over. Hardware that accelerates it
meaningfully is a large chip with high-bandwidth memory attached.

**What is genuinely here** is the primitive underneath all of it. The
number-theoretic transform is how lattice cryptography multiplies
polynomials, and it is the inner loop of ML-KEM, ML-DSA, Falcon and every
practical homomorphic scheme. The engine in `engines/ntt/` is a real,
verified butterfly datapath: 396 butterflies exact against an independent
model, every output checked to be a reduced residue, its port contract
proved.

So the accurate claim is: **this chip has a verified building block for
lattice cryptography, and a credible path to accelerating ML-KEM and ML-DSA
at a useful scale.** Post-quantum key exchange and signatures are reachable.
Fully homomorphic encryption is not, and no amount of tile area changes
that.

### The modulus, and why it was wrong for the goal

The engine shipped with q = 12289, which is Falcon and NewHope's modulus —
not the standardised schemes Caliptra 2.x accelerates:

| scheme | modulus | bits | product | Barrett constant |
|---|---|---|---|---|
| ML-KEM (Kyber) | 3329 | 12 | 24 | 5039 |
| ML-DSA (Dilithium) | 8380417 | 23 | 46 | 8396807 |
| Falcon / NewHope | 12289 | 14 | 28 | 21843 |

The modulus is now a build option and **all three are verified**:

```bash
cd ~/src/hydra-skywater130
make ntt-moduli
```

Two truncations had to be fixed to get there, both invisible at 14 bits: the
Barrett constant was being taken as a fixed 16-bit slice, which silently
discards the top eight bits of ML-DSA's 24-bit constant, and the model wrote
four-digit hexadecimal, which truncates a 23-bit residue into an X rather
than into a wrong number.

Cost of the wider field, in mapped sky130 cells (`make area-ntt`, 2026-10-06):
ML-KEM 7,079 cells / 57,763 µm², Falcon 8,551 cells / 70,524 µm², ML-DSA
not yet measured — its 46-bit products need wider multipliers. (An earlier
draft quoted 11,822 and 14,309: those were yosys generic cells before
technology mapping, not sky130 cells, so they are not comparable.)

---

## Sequestered encryption

The idea in the companion quantum-random-number-generator board: keys live
in a device the host processor cannot read, and the host sends operations
rather than keys. It is the same discipline as Caliptra's key vault, one
board apart.

What this repository would need for it, none of which is built:

- a key slot file the register map can reference but never read back
- a random source; the board project has the entropy hardware
- an engine that takes a slot number instead of a key
- a policy that a slot, once written, cannot be exported

The honest sequencing is: key vault before crypto engine. An engine with no
safe place to keep a key is a demonstration, not a security feature.

---

## Programming the chip: JTAG, USB-C and the serial bridge

You asked for a plain processor so the chip is programmable without
surprises. That instinct is right, and it changes the order of work.

**What exists.** A host link that already works end to end: bytes over a
serial port, a bridge, the register map, and back. `make memboard` drives
matrices in and reads results out over it.

**A plain processor.** Two candidates are already in your projects — the
RV32 control unit from the earlier work and the SimpleOS core. The rule
worth keeping is the one this project has followed: a processor is not
"done" until an independent model agrees with it instruction by instruction.

**Both, now — because two independent ways in is the fault tolerance.** The
test access port is built (`dbg/rtl/hydra_jtag_tap.sv`) and verified: 132
clock edges bit-exact against a model written from IEEE 1149.1's state
diagram, and the standard's escape hatch — five clocks with the mode pin
high reach Test-Logic-Reset **from any state whatsoever** — checked
exhaustively over all sixteen states from an unconstrained start.

That property is why there is no reset pin: the port walks itself home from
wherever it powered up. It is also why the port is worth having beside a
serial link that already works. The two share nothing but the register map
they target — separate clocks, separate state machines, separate pins — so a
fault that takes out one leaves the other. The test port has its own clock,
supplied by the probe, which means it is reachable when the system clock is
wrong, the bridge is misconfigured, or firmware never started.

Cost: **four pins and 491 standard cells, 4,512 µm²** — three percent of the
tile. Cheaper than the argument for leaving it out.

Two things are deliberately not done. There is **no boundary scan**: no scan
cells at the pads, so SAMPLE, PRELOAD and EXTEST are absent and the chip is
not boundary-scan testable. Calling this "JTAG compliant" without that
sentence is a claim a test engineer catches in a minute. The **bridge into the register map** is now written
(`dbg/rtl/hydra_jtag_bridge.sv`): a toggle handshake through two-flop
synchronisers, with the address and data payload crossing UNSYNCHRONISED on
purpose, held still by the handshake. Per-bit synchronisers there would cost
78 flops and make it worse, because each bit would resolve independently and
a word could cross half-old and half-new.

It is checked with the two clocks deliberately not in a neat ratio, and
software polls a busy flag rather than waiting a fixed number of cycles — a
fixed wait passes on a bench and fails on a board whose ratio differs.

One mutation of that bridge SURVIVES simulation: removing a synchroniser
stage. No event simulator can catch it, because metastability is physical
rather than functional. It is caught structurally instead, by
`dbg/formal/cdc_check.py`. What that check cannot do is find a crossing
nobody wrote a synchroniser for; a real clock-domain-crossing tool derives
the domains and finds those.

Still not handled: a system clock that is stopped or broken. No
acknowledgement comes back, the bridge stays busy, and the probe sees that
in the busy flag. Reading registers with the system clock dead would mean
running the register file on the probe's clock, which is a much larger
change and is not pretended here.

**USB-C is a connector, not a protocol.** Nothing on this chip speaks USB.
What makes programming easy is a USB-to-serial bridge *on the board* — an
FT2232H or CH340 — which presents a serial port to the host and plain
transmit and receive pins to the chip. The FT2232H is worth the extra cost
because its second channel can drive JTAG later without another cable. The
chip side stays two pins either way.

---

## Suggested order

1. **Key vault first.** Slots that can be written and used but never read.
   Small, provable, and everything else depends on it.
2. **SHA-256 next.** Test vectors are published, an independent model is
   three lines of Python, and measured boot needs it before anything else.
3. **A measurement register** that only extends.
4. **The plain processor**, verified against a model, reachable over the
   existing serial bridge.
5. **ML-KEM scale-up** of the butterfly engine: more lanes, coefficient
   storage, twiddle generation. This is where the number-theoretic transform
   stops being a primitive and starts being an accelerator.
6. **JTAG**, once there is silicon worth debugging.

Fully homomorphic encryption is not on this list, and should not appear on
the project page either.
