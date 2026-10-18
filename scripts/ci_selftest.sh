#!/usr/bin/env bash
# ci_selftest.sh -- prove that a broken design makes the build fail.
#
# A green check means something only if red is possible. This copies the
# repository to a scratch directory, breaks one thing at a time, and requires
# the matching make target to exit non-zero. Then it runs the targets on the
# unbroken copy and requires them to pass, so a harness that fails everything
# cannot pass either. (Audit R5, 2026-10-11: the multi-modulus loop could not
# fail, and neither could any sv2v-translated testbench, because sv2v turns
# $fatal into $finish(1), which Icarus exits 0 on.)
#
#   scripts/ci_selftest.sh            all injections (about 3 minutes)
#   scripts/ci_selftest.sh --quick    skip the tile's cocotb suite
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK=0; [[ "${1:-}" == "--quick" ]] && QUICK=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
bad=0; n=0

fresh() {   # a clean copy of the repository at $WORK/r
  rm -rf "$WORK/r"; mkdir -p "$WORK/r"
  (cd "$ROOT" && tar --exclude=.git --exclude='fpga/build/*/*.bit' --exclude='*_prove' \
      --exclude='sim_build' --exclude='./build' --exclude='fpga/vendor_refs' -cf - .) | (cd "$WORK/r" && tar xf -)
}

# expect_fail LABEL TARGET [ENV=VALUE...] -- COMMAND THAT BREAKS SOMETHING
expect_fail() {
  local label="$1" target="$2"; shift 2
  local envs=(); while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
  n=$((n+1)); fresh
  (cd "$WORK/r" && eval "$*") || { echo "  ERROR     $label: the breaking command itself failed"; bad=1; return; }
  if (cd "$WORK/r" && env "${envs[@]}" make -s "$target" > "$WORK/out.txt" 2>&1); then
    echo "  SURVIVED  $label: make $target still passed"; bad=1
  else
    echo "  CAUGHT    $label (make $target failed)"
  fi
}

expect_pass() {
  n=$((n+1)); fresh
  if (cd "$WORK/r" && make -s "$1" > "$WORK/out.txt" 2>&1); then echo "  PASS      unbroken: make $1"
  else echo "  BROKEN    unbroken make $1 failed:"; tail -5 "$WORK/out.txt"; bad=1; fi
}

echo "ci_selftest: each break must make its target fail"
# every stage of the multi-modulus loop
for st in model sv2v iverilog sim count; do
  expect_fail "ntt-moduli, $st stage" ntt-moduli NTT_MODULI_INJECT=$st -- true
done
# a wrong result in an sv2v-translated testbench (the $fatal -> $finish(1) hole)
expect_fail "TPU accumulates one too many, sv2v testbench" tpu -- \
  "sed -i 's/acc_q <= acc_q + ACCW.(prod);/acc_q <= acc_q + ACCW\x27(prod) + 1;/' engines/tpu/rtl/tpu_pe.sv && grep -q 'prod) + 1' engines/tpu/rtl/tpu_pe.sv"
expect_fail "dispatcher never retires, system testbench" system -- \
  "sed -i 's/wire do_comp = comp_valid && comp_tag_ok && busy\[comp_i\];/wire do_comp = 1\x27b0;/' mom/rtl/mom_scoreboard.sv && grep -q 'do_comp = 1' mom/rtl/mom_scoreboard.sv"
expect_fail "scratchpad drops every write, sv2v memory testbench" dma -- \
  "sed -i 's/if (we) mem\[addr\] <= wdata;/if (1\x27b0) mem[addr] <= wdata;/' mem/rtl/hydra_spram.sv && grep -q 'if (1' mem/rtl/hydra_spram.sv"
# a compile error, a missing reference model
expect_fail "syntax error in RTL" ntt -- "echo 'module broken(' >> engines/ntt/rtl/ntt_pkg.sv"
expect_fail "reference model missing" simd -- "rm engines/simd/tb/simd_model.py"
expect_fail "formal property broken" padmux -- \
  "sed -i 's/if (!rst_n) assert (pad_oe == .0);/if (!rst_n) assert (pad_oe != \x270);/' common/rtl/hydra_padmux.sv && grep -q 'pad_oe != ' common/rtl/hydra_padmux.sv"
expect_fail "direct-iverilog testbench, every SPI byte dropped" sky130 -- \
  "sed -i 's/if (bitcnt == 3.d7) begin/if (1\x27b0) begin/' mom/rtl/hydra_tt_spi.sv && grep -q 'if (1.b0) begin' mom/rtl/hydra_tt_spi.sv"
if (( ! QUICK )); then
  expect_fail "tile cocotb test fails" tile -- \
    "sed -i 's/assert (s\[\"engine\"\], l\[\"engine\"\]) == (ENG_SIMD, ENG_TPU)/assert False/' tt/tile/test/test.py && grep -q 'assert False' tt/tile/test/test.py"
fi

echo "ci_selftest: the same targets, unbroken, must pass"
for t in ntt-moduli tpu system dma ntt simd sky130 padmux; do expect_pass "$t"; done
(( QUICK )) || expect_pass tile

if (( bad )); then echo "=== ci_selftest: PROBLEMS ABOVE ($n runs) ==="; exit 1; fi
echo "=== ci_selftest: every break was caught, every clean run passed ($n runs) ==="
