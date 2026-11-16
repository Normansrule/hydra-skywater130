# Secure boot for the chip's CPU

Status: **simulated** (2026-10-22). Not hardened, not on a board, nothing formally proved about this block itself. The SHA-256 core and the measurement block it is built on carry their own proofs and hashlib checks (`make sha256`, `make measure`).

This is the SkyWater 130 chip only. The Tiny Tapeout tile stays scheduler-only and has no CPU to boot.

## What it guarantees

On a chip built with `SECURE_BOOT = 1` (`sys/rtl/hydra_sys_tile.sv`), the Sixfold CPU (Central Processing Unit) can run only a program image whose SHA-256 equals `BOOT_GOLDEN`, a 256-bit value fixed in the mask.

1. **Nothing runs before a boot.** Until the image is verified, the CPU slot is not eligible. ABI version 2 refuses a job forced to the CPU with "no engine", and work that only the CPU can do (scalar code) is refused rather than queued. The slot's ready signal is also held low.
2. **A changed image is refused.** The boot reads the image back out of the CPU's own memory, hashes it, and compares. One changed bit anywhere fails it (`make secure-boot` flips one bit at a random position, and `make systile-boot` replaces one instruction).
3. **What was checked is what runs.** The host load port is closed while the image is hashed, and closed for good once it is verified. The entry point is locked with it.
4. **Nothing leaks out afterwards.** After a verified boot, host reads of the CPU's memory and registers return 0.
5. **There is a record.** Every completed boot extends a PCR (Platform Configuration Register): PCR = SHA-256(PCR ‖ digest). The image digest and the PCR can be read back for attestation.

A failed boot leaves the ports open so the host can load a corrected image and try again. Only a reset clears a verified state.

## How the host uses it (control space, bank 3)

| Offset | Write | Read |
|---|---|---|
| 6, 7 | CPU word address, then image words (the existing load port) | |
| 8 | entry point (refused after a verified boot) | |
| 11 | image length in 32-bit words, 1 to 16,384 | |
| 12 | any value: start a boot | |
| 13 | digest word select: 0 to 7 image digest, 8 to 15 PCR, word 0 most significant | |
| 5 | | {verified, failed, busy, load locked, 12'b0, boots[15:0]} |
| 6 | | the selected digest or PCR word |

The image is hashed in memory order, byte 0 first, over exactly the number of words written to offset 11. To verify the whole 64 KiB memory, write 16,384.

## Evidence

| Check | What it shows | Command |
|---|---|---|
| Block against hashlib | a 777-word image: one flipped bit refused; zero length and over-long refused before anything is read; the real image verified; digest and PCR chain equal hashlib's; load port locked for the whole of every boot; no re-boot after a verified one | `make secure-boot` |
| On the six-slot chip | an unbooted CPU and a tampered image are refused through the scheduler; the real Sixfold image (digest from hashlib, `sys/tb/boot_digest.py`) verifies and runs to Sixfold's TOHOST value; all 31 registers and the memory read 0 afterwards; an overwrite of the program and of its entry point is refused, shown by the program running unchanged | `make systile-boot` |
| Mutations | SB-01 to SB-09 in `tools/mutate_mom.py`, each caught by the bench named for it | `python3 tools/mutate_mom.py` |

## What it is not

- **Not signed images.** The root of trust is one digest per mask, so changing the program means a new mask. Verifying signatures (ECDSA or Ed25519) needs a public-key engine, which this chip does not have. That is the next step if field updates are wanted: keep the hash path and add a signature check of the digest against a public key in the mask.
- **No one-time-programmable memory.** SkyWater 130 offers no fuses, so the digest cannot be provisioned after fabrication. That is why it is a mask parameter.
- **No physical security.** Nothing here resists probing, fault injection, glitching or side channels. A glitch that skips the comparison is outside what is checked.
- **The host can still reset the chip.** A reset returns to the unverified state, and the CPU stays refused until the next good boot. That is the intended behaviour, not a bypass.
- **Not in the OpenFrame top yet.** `hydra_openframe_top.sv` holds the scheduler tile only. Secure boot lives with the CPU in `hydra_sys_tile`, which reaches the chip when the engines do.
- **Lint.** The block itself is Verilator `-Wall` clean on 5.032 and 5.051. The existing `sec/` modules it instantiates carry a few warnings (an unused signal, a formal-only parameter, two similar names on 5.051), and they are not in `make lint` yet.
