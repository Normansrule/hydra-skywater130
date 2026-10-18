#!/usr/bin/env bash
# ntt_moduli.sh -- the butterfly engine at every standardised modulus, on its
# own AND through the memory path (host load -> streamer -> engine ->
# serialiser -> result bank), because audit R2 (2026-10-11) found the memory
# format right at one modulus and wrong at the other two -- and the
# memory-path bench had only ever been run at the one.
#
# Replaces a Makefile loop (audit R5, 2026-10-11) that ran the simulator
# inside printf's command substitution: printf succeeded whatever the
# simulator did, so a failed generate, translate, compile or simulate at any
# modulus still exited 0. Here every stage is checked, each modulus builds in
# its own fresh directory (no stale executable can be reused), the vectors
# are deleted before the model writes them (no stale vectors either), the
# simulator must print PASS with the expected case count, and the full log of
# any failure is kept.
#
#   scripts/ntt_moduli.sh                  every modulus
#   scripts/ntt_moduli.sh 3329             one
#   NTT_MODULI_INJECT=<stage> ...          make that stage fail, to prove it is caught
#                                          (model | sv2v | iverilog | sim | count;
#                                           sim corrupts one expected value)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MODULI=("$@")
[[ $# -eq 0 ]] && MODULI=(12289 3329 8380417)
INJECT="${NTT_MODULI_INJECT:-}"
VEC=(engines/ntt/tb/ntt_stim.hex engines/ntt/tb/ntt_exp.hex engines/ntt/tb/ntt_meta.txt)
DVEC=(mem/tb/dma_ntt_jobs.txt mem/tb/dma_ntt_data.hex mem/tb/dma_ntt_meta.txt)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ntt_moduli.XXXXXX")"
KEEP=0
restore() {
  # leave the default (q=12289) vectors behind, as `make ntt` expects
  HYDRA_NTT_Q=12289 python3 engines/ntt/tb/ntt_model.py 4 > /dev/null || true
  HYDRA_NTT_Q=12289 python3 mem/tb/dma_ntt_model.py > /dev/null || true
  (( KEEP )) || rm -rf "$WORK"
}
trap restore EXIT
fail() { echo "FAIL ntt-moduli q=$1: $2 (log: $WORK/q$1/log.txt)"; KEEP=1; exit 1; }

for Q in "${MODULI[@]}"; do
  D="$WORK/q$Q"; mkdir -p "$D"; LOG="$D/log.txt"; : > "$LOG"
  rm -f "${VEC[@]}"
  model=(python3 engines/ntt/tb/ntt_model.py 4)
  [[ "$INJECT" == model ]] && model=(python3 -c 'raise SystemExit(3)')
  HYDRA_NTT_Q=$Q "${model[@]}" >> "$LOG" 2>&1 || fail "$Q" "reference model failed"
  for f in "${VEC[@]}"; do [[ -s "$f" ]] || fail "$Q" "model wrote no $f"; done
  want=$(grep -c . engines/ntt/tb/ntt_meta.txt)

  src=(engines/ntt/rtl/*.sv engines/ntt/tb/tb_ntt.sv)
  [[ "$INJECT" == sv2v ]] && src+=(engines/ntt/rtl/does_not_exist.sv)
  sv2v --define=HYDRA_NTT_Q="$Q" "${src[@]}" > "$D/ntt.v" 2>> "$LOG" || fail "$Q" "sv2v failed"
  [[ "$INJECT" == iverilog ]] && echo "module broken(" >> "$D/ntt.v"
  iverilog -g2012 -o "$D/sim" "$D/ntt.v" >> "$LOG" 2>&1 || fail "$Q" "iverilog failed"

  # a wrong expected value: the testbench itself must catch it
  [[ "$INJECT" == sim ]] && python3 -c "import sys;p='engines/ntt/tb/ntt_exp.hex';l=open(p).read().split();l[0]=format(int(l[0],16)^1,'x');open(p,'w').write(chr(10).join(l)+chr(10))"
  set +e; vvp -n "$D/sim" > "$D/sim.txt" 2>&1; rc=$?; set -e
  cat "$D/sim.txt" >> "$LOG"
  (( rc == 0 )) || fail "$Q" "simulation exited $rc"
  line=$(grep -E '^PASS tb_ntt' "$D/sim.txt" || true)
  [[ -n "$line" ]] || fail "$Q" "no PASS line"
  got=$(sed -nE 's/^PASS tb_ntt: ([0-9]+) cases.*/\1/p' <<< "$line")
  [[ "$INJECT" == count ]] && got=$((got - 1))
  [[ "$got" == "$want" ]] || fail "$Q" "ran $got cases, the model wrote $want"
  printf 'PASS ntt-moduli q=%-8s %s\n' "$Q" "${line#PASS tb_ntt: }"

  # ---- the same modulus through memory -----------------------------------
  rm -f "${DVEC[@]}"
  HYDRA_NTT_Q=$Q python3 mem/tb/dma_ntt_model.py >> "$LOG" 2>&1 || fail "$Q" "memory-path model failed"
  for f in "${DVEC[@]}"; do [[ -s "$f" ]] || fail "$Q" "memory-path model wrote no $f"; done
  sv2v --define=HYDRA_NTT_Q="$Q" engines/ntt/rtl/*.sv mem/rtl/*.sv sys/rtl/hydra_engine_ntt_dma.sv \
       mem/tb/tb_hydra_dma_ntt.sv > "$D/dma.v" 2>> "$LOG" || fail "$Q" "memory-path sv2v failed"
  iverilog -g2012 -o "$D/dma" "$D/dma.v" >> "$LOG" 2>&1 || fail "$Q" "memory-path iverilog failed"
  set +e; vvp -n "$D/dma" > "$D/dma.txt" 2>&1; rc=$?; set -e
  cat "$D/dma.txt" >> "$LOG"
  (( rc == 0 )) || fail "$Q" "memory-path simulation exited $rc"
  grep -qE '^FAIL|Fatal \[' "$D/dma.txt" && fail "$Q" "memory-path simulation printed a failure"
  dline=$(grep -E "^PASS tb_hydra_dma_ntt: q=$Q," "$D/dma.txt" || true)
  [[ -n "$dline" ]] || fail "$Q" "memory path: no PASS line for q=$Q"
  printf 'PASS ntt-moduli q=%-8s memory path: %s\n' "$Q" "${dline#PASS tb_hydra_dma_ntt: q=$Q, }"
done
