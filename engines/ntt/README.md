# NTT — streaming butterfly engine over GF(12289)

Coefficient pairs and their twiddle factor in, two reduced residues out,
four butterflies per cycle.

| file | job |
|---|---|
| `rtl/ntt_pkg.sv` | the field, the Barrett constant, widths, status |
| `rtl/ntt_modmul.sv` | (a·b) mod q by Barrett reduction |
| `rtl/ntt_butterfly.sv` | one Cooley-Tukey butterfly, registered |
| `rtl/ntt_lanes.sv` | four of them |
| `rtl/ntt_ctrl.sv` | the only state machine |
| `rtl/ntt_top.sv` | engine port and descriptor decode |
| `tb/ntt_model.py` | the arithmetic, and it asserts the Barrett bound |
| `tb/tb_ntt.sv` | field corners then random, stalls, refusals |
| `formal/ntt_ctrl.sby` | port contract, proved |
| `formal/mutate_ntt.py` | nine breaks |

## What it is not

**Not a transform.** A full number-theoretic transform over n coefficients
is log₂(n) passes with a different pairing each time. The addressing that
produces those pairings belongs in the direct memory access engine, next to
the memory it reads — putting it here would hide the transform's memory
behaviour from the dispatcher's cost model, which is the one thing that
model has to be able to see.

So: one pass over the data is one stage. Software or the DMA engine issues
log₂(n) descriptors.

## Why Barrett rather than Montgomery

Montgomery is cheaper per multiply but requires operands in a transformed
domain, so the conversion has to live somewhere, and "somewhere" ends up
being software. Barrett takes residues as they are, which keeps the
engine's contract to *integers mod q in, integers mod q out* — the contract
the model checks.

## Measured

| property | value |
|---|---|
| correctness | 32 cases, 396 butterflies exact against the model |
| every output reduced | checked on every result, not just compared |
| port contract | proved by k-induction |
| mutations | 8 killed, 1 proven equivalent |

## The equivalent mutation, and why it stays

Reducing the Barrett constant by one survives every test. It is not a
missing test: swept across the whole product range, the largest
intermediate remainder with `BM−1` is **22,887**, still under 2q = 24,578,
so the single conditional subtract closes it and the answers are
identical. The mutation is kept in the list, labelled, with the number —
deleting it would lose the evidence that the reduction has margin.
