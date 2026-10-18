# Sequestered execution (SE) contract, version 0 (proposed)

**Status: SPECIFICATION, NOT IMPLEMENTED.** Every SE cell in the capability
matrix is UNSUPPORTED, and the host driver refuses SE jobs.

## Definition

Data is encrypted everywhere outside a **trusted region**. Inside it,
authorised operations decrypt, compute and re-encrypt. The trusted region
contains **every** place SE plaintext or keys can exist: the key store,
decrypt and encrypt endpoints, operand and result storage, engine
registers, accumulators, FIFOs, pending results, and interrupt and status
paths that could carry data. A boundary drawn around the cipher block alone
does not meet this definition.

## Required parts (Gate E)

| part | requirement | exists today |
|---|---|---|
| root of trust | a key the host never sees, generated internally or provisioned over an authenticated channel | no. The vault takes host-written keys |
| lifecycle | DEVELOPMENT and PRODUCTION states. Debug ports confined or off in PRODUCTION, and a debug image can never present itself as production | no |
| authenticated encryption | AES-GCM (NIST SP 800-38D) or an equivalent standard mode | no |
| nonces | a documented construction, unique per key, with a counter that survives reset (non-volatile or re-keyed on every boot) | no |
| binding | each protected object bound to its context ID, epoch, address or object ID, version and permissions | no |
| anti-replay and rollback | versioned objects. A stale version is rejected | no |
| access enforcement | hardware checks on the host, DMA and debug masters for every trusted bank | partly. R8 refuses host **writes** during a job. Reads and the idle period are not enforced |
| output policy | plaintext output is suppressed when authentication fails. Declassification happens only through named, authorised operations | no |
| zeroisation | every secret-bearing register and memory cleared on context exit, reset and failure | no. The vault wipe covers the key slots only |
| information flow | a stated property, for example no flow from SE plaintext to a public output except through declassify, checked on the RTL | no |

## Declassification

An untrusted program must not decrypt a secret and then store it to a
public output. Comparison results, branch outcomes, early exits and error
codes are disclosures. Each one is either kept encrypted or listed as an
allowed declassification.

## Engines

For an engine to support SE, its complete plaintext state is inside the
trusted region, or its interface works only on encrypted operands with
tightly defined operations. Plaintext copied to an ordinary GPU outside the
region is not SE. Until an engine's state has been placed in the region and
tested, its SE cell stays UNSUPPORTED.

## Tests required before any SE cell is advertised

Unauthorised reads and writes from the host, DMA and debug; tampered
ciphertext; replay of an old object; a wrong context; a debug attempt in
PRODUCTION; failed authentication with no plaintext output; key lifecycle;
reset and zeroisation at every pipeline state; and the declared leakage
model checked against what is observable.
