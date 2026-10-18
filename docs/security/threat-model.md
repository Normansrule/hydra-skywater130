# Threat model

**Status: SPECIFICATION. Nothing here is implemented as a security contract.**
Today every build runs in `PUBLIC_DEBUG`: anything the host sends, the host
and anyone with the board can see. The host driver refuses FHE and SE jobs
(`tools/hydra_host.py check_job`). This document sets the boundary that
future work must meet before either mode is offered.

## Assets

| asset | why it matters |
|---|---|
| client plaintext (FHE) | must never exist outside the client |
| FHE secret key | must never leave the client; the evaluator holds only public and evaluation keys |
| SE data keys | plaintext exists only inside the trusted region, under these keys |
| SE plaintext state | operands, accumulators, FIFOs, pending results and engine registers while decrypted |
| context identity and epoch | stop an old completion, tag or nonce from acting in a new context |
| nonce counters | must never repeat under one key, including across reset |
| results' integrity | the client must be able to tell tampered output from real output (SE). FHE gives confidentiality, not verifiable computation |

## Parties

| party | trusted? |
|---|---|
| client | trusted for its own data and keys |
| host PC and its driver | **untrusted** in FHE and SE. It may send any byte at any time, replay, reorder or drop traffic, and reset the board |
| serial bridge and dispatcher | untrusted in FHE. In SE, untrusted for data and trusted only to enforce the boundary checks it implements |
| SE trusted region | trusted. It must contain every place SE plaintext or keys exist (see `se-contract.md`) |
| debug ports (JTAG, pin mode) | untrusted in any production lifecycle state; disabled or confined there |

## In scope

- Host reads and writes to any bank, register or engine port at any time.
  The R8 ownership check is a functional fix, not yet a security boundary.
- Malformed, replayed, reordered, truncated or out-of-range descriptors.
- Resets and power loss at any point, including mid-job and mid-transition.
- Delayed or stale completions that reuse a tag.
- Mode or context changes requested by an unauthenticated party.
- Debug access in a production state.

## Out of scope until stated otherwise

Each of these needs its own analysis before anyone claims coverage:

- **Timing.** The Sixfold CPU has a variable-latency divider, caches and a
  branch predictor. Encrypted memory alone gives no constant-time claim.
- **Access patterns** (addresses on the external bus).
- **Power and electromagnetic side channels**, and fault injection.
- **Physical probing** of the FPGA or the board.
- **Supply chain**: the bitstream toolchain, board firmware and the FPGA
  vendor.

## What the existing primitives do and do not give

| primitive | gives | does not give |
|---|---|---|
| key vault | slots usable by number, not readable by the host read port; lock and wipe | proof the host never knew a key. The host writes the keys, and the vault is volatile |
| SHA-256 and the measurement register | a hash and an extend-only measurement | authenticated boot or attestation. There is no immutable root key, signer or verifier |
| bank ownership (R8) | the host cannot change an engine's operands or results mid-job | confidentiality. The host can read the banks before and after a job |
| NTT butterflies | one primitive of lattice cryptography | a transform, ciphertext arithmetic or any FHE operation by itself |

## Rules every future mode must keep

1. A job is refused when the mode it asks for cannot be honoured. It is
   never downgraded.
2. A job's mode and context are fixed when it is admitted. The host cannot
   change them afterwards.
3. Switching modes changes how **new** jobs are handled. It never converts
   existing ciphertext. Converting data between FHE and SE needs the client
   to decrypt and re-encrypt, or a separately designed and authorised
   protocol.
4. No claim (README, datasheet, badge) goes further than the
   capability matrix.
