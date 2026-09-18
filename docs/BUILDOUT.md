# Build-out: the sixteen expansions

One of the sixteen is built. This document is the contract for the other
fifteen, in the order they unblock each other, so each one arrives with its
verification rather than after it.

## What "built" means here

Nothing counts as done without all four, which is how the crossbar below was
done:

1. a **testbench against an independent model** written from the block's
   contract, compared exactly, every cycle;
2. **formal properties** with **mutations that must die** — and where a proof
   cannot see a mutation because it assumes the environment behaves, that
   mutation moves to the simulation list rather than being deleted;
3. **integration** with something real, not a stub of itself;
4. a **header explaining why**, including what went wrong and how it was
   found.

---

## 1. Engine crossbar — BUILT (session 179c)

`common/rtl/mom_xbar.sv`. The MOM decides; nothing carried the decision out.
This routes dispatches to the chosen engine and completions back.

| check | result |
|---|---|
| independent model, `xbar_model.py` | 20,000 vectors, exact, including engines that lie |
| formal, k-induction | proved, including "no completion is lost" |
| mutations | 6/6 formal, 3/3 simulation killed |
| integration, `tb_mom_system.sv` | 42 dispatched, 42 completed, zero errors |
| the loop closes in hardware | TPU → SIMD after 31 dispatches, **no host involved** |

Two real bugs it caught, both of the kind that survive to silicon:

- `disp_accept` was asserted while reset was low. The independent model,
  written from the contract, expected no accept during reset.
- `eng_tag` carried the *previous* tag to an engine being started, because
  `tag_q` only updates at the end of the cycle. Every completion came back
  unknown. Found by the system bench, invisible to the unit tests.

That last one is the argument for step 3 of the contract above.

---

## 2. Next, in dependency order

### TRNG source + pool (~6,000 cells)
`trng_health` exists and has no input. Add `trng_source` (ring oscillators,
`rtl/puf/ro_cell.sv` is the cell) and `trng_pool` (conditioning plus a FIFO
gated on `healthy`).

- **Model**: entropy is not modelled; the *interface* is. The model is a
  FIFO with a health gate, and the test drives recorded RO samples.
- **Properties**: no sample leaves the pool while `healthy` is low; the FIFO
  never returns a word twice; reset empties it.
- **Statistical checks are separate** and belong on hardware: run the FPGA
  build feeding the pool from the QRNG board's diode and apply NIST SP 800-90B
  to the captured stream. An on-chip test cannot prove randomness, and a
  proof that claims to is worse than none.
- **Watch for**: on FPGA, ring oscillators are weak and the bitstream is
  readable. The FPGA build must force the lifecycle to DEV and use test keys.

### SHE CMAC path (~12,000 cells)
`upd_mac_ok` is tied low, deliberately, so the keystore is safe and unusable.
Route the authorising key from the keystore read port into a CMAC engine over
the existing AES core, and compare the tag **in gates**.

- **Model**: AES-CMAC from the specification in Python; compare against
  NIST SP 800-38B vectors first, then against the RTL.
- **Properties**: the compare result is never observable before it is
  complete; a one-bit tag difference always rejects; `upd_mac_ok` can only
  rise from a completed compare.
- **Never**: make the result a CSR bit. That reduces the whole SHE model to
  a formality, as the handoff says.

### RAM ECC + bus fault unit (~10,000 cells)
SECDED on the data RAM, a fault unit that traps rather than corrupts.

- **Model**: the Hamming code in Python; inject every single-bit error
  (must correct) and every double-bit error (must detect, must trap).
- **Properties**: corrected data always equals the written data; an
  uncorrectable error always raises the trap and never returns data.
- **Integration**: through the real bus, in `tb/soc`.

### Dual-core lockstep (~25,000 cells)
Two `core_pipe` instances, one delayed, with a comparator. Both cores already
pass the same 59/59 SoC suite, which is what makes this cheap.

- **Properties**: any divergence raises the fault before the write commits —
  the interesting one, and the reason the delay exists.
- **Test**: inject a fault into one core's register file and require the
  comparator to catch it within the delay window. A lockstep pair that has
  never been made to disagree is untested.

### RISC-V PMP (~8,000 cells)
- **Model**: the PMP matching rules from the privileged specification. The
  edge cases (NAPOT boundaries, overlapping regions, locked entries) are the
  whole point; write the model from the spec text, not from the RTL.
- **Properties**: a locked entry never changes until reset; no access is
  permitted that no region permits.

### Monitors and watchdog safe state (~5,000 cells)
Voltage, temperature and clock-glitch monitors feeding `RESET_CAUSE`; the
watchdog wired into `pwm_gen`'s fault input so the inverter switches open
*before* anything resets.

- **Property**: from watchdog expiry, the PWM outputs are inactive within one
  cycle, under every state of the rest of the machine. This is the safety
  property of the whole chip; prove it, do not test it.

### Multi-axis motor control (~3,000 cells per axis)
Replication of the verified axis blocks plus arbitration — the same pattern
`ecdsa_top` and now `mom_xbar` use.

- **Property**: two axes never drive the same PWM pair; an axis in fault
  cannot be re-enabled without an explicit clear.
- **Test**: six axes with different reference profiles, checking each axis's
  output against its own single-axis reference run. Replication bugs hide in
  the cross terms.

### CAN-FD + SecOC (~21,000 cells)
- **Model**: bit stuffing, arbitration and CRC from ISO 11898-1 in Python;
  test against recorded traffic, not self-generated frames.
- **Properties**: bit stuffing is always removable; an arbitration loss never
  corrupts the losing frame's retransmission.
- **SecOC** reuses the HMAC core: freshness counters must be monotonic and a
  replayed frame must be rejected — a directed test, not a random one.

### Sensor capture, SPI offload, absolute encoders (~15,000 cells)
A global timestamp counter plus trigger/capture; a SPI slave so the chip can
sit beside a bigger SoC; BiSS-C or SSI for absolute position.

- **Property**: samples captured by one trigger all carry the same timestamp.
  Sensor fusion is unusable without that, and it is easy to get wrong.

### USB protocol engine + CDC (~20,000 cells)
The wire layer has been done since session 157; tokens, endpoints and
enumeration remain.

- **Test**: against a host model, through enumeration, with deliberate
  errors (a corrupted token, a NAK storm). Enumeration working once is not
  the same as enumeration working.

### Authenticated debug, measured boot, PUF provisioning (~23,000 cells)
- **Properties**: debug is refused unless a challenge was answered with the
  device key; the lifecycle state machine never moves backwards; a
  measurement register cannot be written twice between resets.
- **Test**: the negative cases are the test. Try to unlock without the key,
  try to re-measure, try to move the lifecycle back.

### ML-KEM (Kyber) on the NTT (~40,000 cells)
The NTT is already at Kyber parameters.

- **Model**: the reference implementation's known-answer tests. Nothing else
  is acceptable for a standardised algorithm.
- **Properties**: constant-time behaviour — the cycle count must not depend
  on secret data. Prove it as an equivalence between two secret inputs.

### Fault-injection hardening (~30,000 cells)
Redundant computation on the signature path plus glitch detection.

- **Test**: inject single-cycle faults into every state element of the
  signature datapath in turn and require detection. Automate it; a hand-
  picked fault list tests the person, not the design.

### GPU sizing (unknown)
The handoff has no place-and-route number for the GPU. Before anything else,
run `tools/verify_all.sh block gpu_top` and put a real number in
`docs/CAPACITY.md`, where it currently says GUESS: 80,000 cells.

### Ethernet / TSN MAC (~60,000 cells)
Large, and last. Only worth starting once the chip has a reason to be on a
network, which is fleet attestation rather than robotics.

---

## 3. What this needs from an FPGA

`docs/CAPACITY.md` has the measured conversion. The whole roadmap plus the
existing SoC is roughly 620,000 sky130 cells, about 166,000 Xilinx LUT6.

| board | LUT6 | roadmap needs | headroom |
|---|---|---|---|
| ECP5-85F evaluation board | 83,640 LUT4 | 207% of it for the SoC alone | none, but right for block-by-block work |
| Nexys Video (Artix-7 200T) | 134,600 | 123% | no |
| **Genesys 2 (Kintex-7 325T)** | **203,800** | **81%** | thin but real |
| ZCU104 (Zynq UltraScale+) | ~230,000 | 72% | more, and ARM cores beside it |

**Recommendation: keep the ECP5 evaluation board for the work you are doing
now, and buy a Genesys 2 only when you genuinely need the whole machine in
one image.** Block-by-block bring-up is what this roadmap consists of, and
every single entry above fits beside the tile on the ECP5. Spending $1,200
before that is buying capacity for an integration you are not ready to do.

When you do need it: Genesys 2 at 81% is tight for a design still growing.
The cheaper way out is the one that also helps the chip — share the three
`p256_modmul` instances down to one (about 22,000 cells) and put the data RAM
in an SRAM macro. ECDSA is 55% of the SoC; it is the only block whose size
really decides which board you need.
