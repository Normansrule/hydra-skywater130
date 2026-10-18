#!/usr/bin/env bash
# check_deps.sh -- every tool and Python package `make verify` needs, checked
# up front, so a missing one is named in the first second instead of as a
# traceback halfway through (2026-10-18: a conda environment without PyYAML
# stopped site-check after a minute of simulations).
missing=0
for t in python3 node sv2v iverilog vvp verilator yosys sby; do
  command -v "$t" >/dev/null || { echo "check-deps: '$t' not found on PATH"; missing=1; }
done
py=$(command -v python3)
for m in yaml cocotb; do
  python3 -c "import $m" 2>/dev/null || {
    echo "check-deps: Python package '$m' missing for $py"
    echo "            install it (python3 -m pip install $( [ $m = yaml ] && echo pyyaml || echo $m )), or leave the active environment (conda deactivate)"
    missing=1; }
done
[ -n "${CONDA_DEFAULT_ENV:-}" ] && [ $missing = 1 ] && echo "check-deps: conda environment '$CONDA_DEFAULT_ENV' is active"
[ $missing = 0 ] && echo "PASS check-deps: tools and Python packages present ($py)"
exit $missing
