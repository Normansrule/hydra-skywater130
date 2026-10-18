# Evidence: second engineering audit, 2026-10-11

Logs produced while closing the audit
([`docs/audit/second-audit-closure.md`](../../docs/audit/second-audit-closure.md)),
on the baselines named there plus this release's changes, with the tools in
`tools.txt`. Simulation and formal only. **No FPGA place-and-route and no
physical board** were run for this report (nextpnr is not installed here).

| file | what it shows |
|---|---|
| `verify_summary.log` | every PASS line of `make -k verify` (exit 0) |
| `ci_selftest.log` | `scripts/ci_selftest.sh`: 13 injected breaks all caught, 9 clean targets pass |
| `dma_mutate.log` | `make dma-mutate`: 26 of 26 memory-path mutations killed, including each audit fix put back |
| `tile_mutate.log` | `tt/tile/test/mutate_sim.py`: 17 of 17 tile mutations killed |
| `before/r8_*.log` | the R8 benches against the RTL **before** bank ownership: results and operands corrupted |
| `before/r5_ntt_moduli_injections.txt` | each injected failure stage of `ntt_moduli.sh`, now reported as a failure |

Reproduce with the commands at the end of the closure document.
