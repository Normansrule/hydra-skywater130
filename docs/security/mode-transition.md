# Mode and context transition (proposed)

**Status: SPECIFICATION, NOT IMPLEMENTED.** No build changes security mode,
because only `PUBLIC_DEBUG` exists. This state machine is the contract any
future implementation must meet. It is a control-plane transition, not a
mode bit.

## States

```
ACTIVE ──request (authenticated)──▶ QUIESCE ──▶ DRAIN ──▶ ZEROIZE ──▶ INSTALL ──▶ ACTIVE (epoch + 1)
   ▲                                   │          │          │           │
   └──────────── FAILED (safe) ◀───────┴──────────┴──────────┴───────────┘
```

| state | does | leaves when | timeout → |
|---|---|---|---|
| ACTIVE | runs jobs of the current context and epoch | an authenticated transition request arrives | — |
| QUIESCE | stops admitting new jobs to the affected context. Queued jobs that have not started are cancelled with a defined status | the admission path is closed | FAILED |
| DRAIN | waits for engines, streamers, serialisers and memory commits. A completion counts only when its results are committed (the R1/R3 commit barrier) | every engine is idle and nothing is in flight | FAILED |
| ZEROIZE | clears every secret-bearing register and bank of the old context, and invalidates its tags and key handles | every scrub completes and is checked | FAILED |
| INSTALL | authenticates the new context descriptor (mode, keys or handles, permitted engines and capabilities) | the checks pass | FAILED |
| ACTIVE (new) | publishes epoch + 1. Only now are jobs admitted | — | — |
| FAILED | admits nothing. Secret-bearing state is zeroised. Leaving it needs an authenticated reset into a known context | — | — |

## Invariants

1. **Epoch on every tag.** A completion carries the epoch it was admitted
   in. A completion from an older epoch is dropped and counted; it never
   retires a job in the new epoch. The current tile's 4-bit tag has no
   epoch, so this needs a versioned completion format.
2. **Mode fixed at admission.** The host cannot change a job's mode, context
   or key handle after admission.
3. **No conversion.** A transition changes how new jobs are protected. It
   never reinterprets existing ciphertext. FHE ↔ SE conversion of data is a
   separate, explicitly authorised operation.
4. **Reset is a transition to FAILED,** not back to the previous context.
   Nonce state survives it or the key is replaced, so a reset cannot cause
   nonce reuse.
5. **No downgrade without authentication.** A request for a weaker mode
   needs the same authentication as any other.
6. **Retained state is listed.** Anything kept across the transition (for
   example FHE public or evaluation keys) is named in the context descriptor
   and authenticated. Nothing else survives.

## Tests required (Gate F)

A transition requested at every pipeline state, with writes outstanding,
queues near full, a stalled engine (the timeout path), failed
authentication, repeated tags across the boundary, reset in each state,
and many transitions back to back. Each test checks that no result from the
previous context is readable in the next.
