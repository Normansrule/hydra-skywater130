# Security instructions for the RV64 core

Two parts: the **ratified** SHA-256 subset of the RISC-V Scalar Cryptography
extension, and a small **custom** extension, `Xhydrasec`, for what only this
chip has. Implemented in `isa/rtl/hydra_xsec_unit.sv`.

---

## Why not invent everything

RISC-V already ratified cryptography instructions — *Cryptography Extensions
Volume I: Scalar & Entropy Source Instructions*, v1.0.1. Compilers and
crypto libraries target them today. A private SHA instruction would make
this chip incompatible with all of that for no gain. So the arithmetic is
**standard**, and the custom space holds only what no standard covers: the
key vault, the measurement register, and a guaranteed constant-time compare.

---

## Part 1 — Zknh, SHA-256 subset (standard)

Encodings from the official `riscv-opcodes` table, `extensions/rv_zknh`.
Format: `0001000 SSSSS rs1 001 rd 0010011`, where `SSSSS` selects the function.

| instruction | `SSSSS` | result |
|---|---|---|
| `sha256sum0 rd, rs1` | `00000` | Σ0: ror(x,2) ⊕ ror(x,13) ⊕ ror(x,22) |
| `sha256sum1 rd, rs1` | `00001` | Σ1: ror(x,6) ⊕ ror(x,11) ⊕ ror(x,25) |
| `sha256sig0 rd, rs1` | `00010` | σ0: ror(x,7) ⊕ ror(x,18) ⊕ (x ≫ 3) |
| `sha256sig1 rd, rs1` | `00011` | σ1: ror(x,17) ⊕ ror(x,19) ⊕ (x ≫ 10) |

On RV64, `x` is the **low 32 bits** of `rs1` and the 32-bit result is
**sign-extended** into `rd`, exactly as the specification's execute clauses
state. Both halves of that rule have dedicated test vectors, because an
implementation that uses all 64 bits, or zero-extends, passes most random
tests and fails real software.

---

## Part 2 — Xhydrasec (custom)

Opcode `custom-0` (`0001011`), which RISC-V reserves for vendor extensions,
so it cannot collide with a future standard. R-type, `funct7 = 0000000`.

| `funct3` | instruction | effect | privilege |
|---|---|---|---|
| `000` | `hsec.kvstat rd, rs1` | status of key slot `rs1`: filled, sealed, geometry. **No key bits.** | any |
| `001` | `hsec.kvwrite rs1, rs2` | write 32 bits of `rs2` into the slot and word named by `rs1` | **machine** |
| `010` | `hsec.kvlock rs1` | seal slot `rs1` until the next wipe | **machine** |
| `011` | `hsec.pcrrd rd, rs1` | 64 bits of the measurement register; word 0 is most significant | any |
| `100` | `hsec.measw rs1, rs2` | stage 32 bits of a measurement | any |
| `101` | `hsec.pcrext` | fold the staged measurement into the register | any |
| `110` | `hsec.cteq rd, rs1, rs2` | 1 if equal, else 0, in constant time | any |
| `111` | — | reserved: **illegal instruction** | — |

For `kvwrite`, `rs1` carries the slot in its upper field and the word index
in its low bits; the exact split follows from the vault's geometry
parameters.

### There is no key-read instruction

That is deliberate and it is the point. Software refers to keys by slot
number; an engine uses them; nothing returns them. `kvstat` returns
metadata only.

### Why `hsec.cteq` exists

Software cannot reliably write a constant-time comparison: compilers turn a
loop over bytes into an early-exit branch, and comparing an authentication
tag with an early exit leaks how many leading bytes were correct. In
hardware a 64-bit compare takes one cycle whatever the operands, and this
instruction makes that a guarantee rather than a hope.

### Why a trap and not a silent no-op

A key write attempted outside machine mode raises an **illegal-instruction
trap**. Silently ignoring it would teach developers nothing went wrong and
teach an attacker nothing was there to hit.

---

## What is verified

| property | how | result |
|---|---|---|
| All four Zknh functions, both RV64 halves | 184 vectors against a model whose functions are first checked by reproducing a full SHA-256 against `hashlib` | exact |
| `hsec.cteq` | 40 vectors, half equal, half differing in one random bit | exact |
| Privilege: user, supervisor, machine | vectors for each, plus the reserved encoding | exact |
| Key writes and seals **cannot** happen outside machine mode, and trap | **proved**, all operands | holds |
| An illegal instruction changes **nothing** | **proved** | holds |
| **No instruction sequence moves key bits into a register** | **non-interference**: two copies with identical instruction streams and different keys produce identical results | holds, bounded to 12 instructions |

The last proof was checked for teeth: re-injecting a one-bit key leak into
the vault's status word is caught at step 3, with the exact instruction
sequence — write a key, then read its status — that exposes it.

### Stated limits

- **Timing** is data-independent because everything is single-cycle
  combinational, which is the strongest form of the Zkt guarantee. It is not
  separately measured, and power side channels are not addressed at all.
- The non-interference result is **bounded** (12 instructions, two 64-bit
  slots). The shipped vault is larger.
- **The unit is not yet wired into a core.** It is a verified functional
  unit with a documented decode; connecting it to the RV64 pipeline — and
  getting the illegal-instruction trap into the core's exception logic — is
  the next integration step, and a core without that wiring does not have
  these instructions.
- **No assembler support.** Until the toolchain knows the mnemonics, the
  custom instructions are emitted with `.insn r 0x0B, <funct3>, 0, rd, rs1,
  rs2`. The Zknh instructions need no such workaround: current GNU and LLVM
  toolchains accept them with `-march=rv64gc_zknh`.
