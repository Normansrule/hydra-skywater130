# FHE profile, version 0 (proposed)

**Status: SPECIFICATION, NOT IMPLEMENTED.** Every FHE cell in the capability
matrix is UNSUPPORTED, and the host driver refuses FHE jobs.

## Contract

An evaluator that does not hold the client's secret key computes on
ciphertext. It may hold public and evaluation keys. The client encrypts,
the evaluator computes, and only the client decrypts. The evaluator never
decrypts to serve a request, and an FHE job is never run in plaintext as a
fallback.

FHE gives **confidentiality**. It does not show that the evaluator computed
the requested function: ciphertexts are malleable by design. Transport
integrity and verifiable computation are separate properties, and this
profile claims neither.

## First scheme: BFV, exact integer arithmetic

BFV is chosen first because HYDRA's existing arithmetic is exact modular
integer work: Barrett butterflies, INT8 and INT32 lanes. Results can be
compared bit for bit with a software reference. CKKS (approximate,
tensor-friendly) is the natural second profile. TFHE/FHEW (Boolean, lookup
tables) needs a different datapath and is not planned.

| item | value |
|---|---|
| reference library | OpenFHE, pinned to an exact release and commit, recorded in `fhe/REFERENCE` (to be created) |
| parameter authority | OpenFHE's parameter generation at a stated security level. **No home-grown parameters** |
| security target | 128-bit classical, per OpenFHE's tables. TBD until generated |
| ring degree N, modulus chain, plaintext modulus t | TBD, taken from OpenFHE for the first workload. Not chosen here |
| multiplicative depth | TBD by the workload. The profile is **leveled**, with no bootstrapping |
| bootstrapping | **not offered.** A depth limit is stated per parameter set, and deeper circuits are refused |
| first workload | a small encrypted integer matrix-vector product, decrypted by the client and compared exactly with plaintext |

## Host and hardware split

Stage 1 is all software, as the reference: client key generation and
encryption, evaluation by OpenFHE on the host, and client decryption with an
exact comparison. Hardware offload is added one primitive at a time, each
compared against the stage 1 trace:

| primitive | needed for | what HYDRA has | gap |
|---|---|---|---|
| full forward and inverse NTT over N points | polynomial multiply | 4 butterflies, ≤ 23-bit moduli | transform control, twiddle storage, N-point banking, inverse scaling |
| RNS limbs | every ciphertext operation | none | OpenFHE limbs are typically wider than 23 bits. This needs a wider modular datapath or a limb size chosen to fit, justified against the security target |
| key switching and relinearisation | ciphertext multiply | none | — |
| modulus switching | depth management | none | — |
| rotations (batching) | vector workloads | none | — |

**The INT8 array is not an FHE engine.** Multiply-accumulate on ciphertext
bytes does not implement ciphertext algebra. The TPU stays UNSUPPORTED for
FHE until a modular RNS datapath exists for it.

## Data movement

One ciphertext with N = 8192 and four 64-bit limbs is 512 KiB. At 115200
baud that takes about 45 s, before any keys. The serial link is for control.
FHE data needs DDR-backed DMA and a faster host link on a larger board (see
the second audit, section 12), and that board must be synthesised with the
real design before anyone claims it fits.

## Acceptance (Gate D)

- Client encrypt → evaluate → client decrypt matches plaintext exactly, over
  randomised inputs, at the stated depth.
- The secret key is never present on the evaluator, checked by inspecting
  what the evaluator is given.
- A wrong key, context or parameter set is rejected.
- The host and hardware split and the depth limit are stated next to every
  result.
