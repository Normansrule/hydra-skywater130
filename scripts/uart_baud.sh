#!/usr/bin/env bash
# uart_baud.sh -- every generated board image's serial port against an
# independently timed 115200-baud host, at -2%, 0 and +2% host clock error.
#
# The clock and divisor are read from the generated top files
# (fpga/build/*/hydra_*.sv, "// UART: <f> MHz / <n> = ..."), i.e. what
# tools/hydra_bind.py actually emitted for each plan -- not recomputed here.
# Audit R4 (2026-10-11): the ULX3S image ran 4.3% fast and failed against a
# host 2% fast; the Arty and Tang Nano images ran at about twice the rate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/uart_baud.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
sv2v fpga/rtl/hydra_fpga_uart.sv > "$WORK/uart.v"
n=0
for top in fpga/build/*/hydra_*.sv; do
  line=$(grep -m1 '// UART:' "$top" || true)
  [[ -n "$line" ]] || continue
  mhz=$(sed -E 's#.*UART: ([0-9.]+) MHz / ([0-9]+) =.*#\1#' <<< "$line")
  div=$(sed -E 's#.*UART: ([0-9.]+) MHz / ([0-9]+) =.*#\2#' <<< "$line")
  hz=$(python3 -c "print(round($mhz * 1e6))")
  for ppm in -20000 0 20000; do
    iverilog -g2012 -DF_HZ="$hz" -DDIV="$div" -DPPM="$ppm" -o "$WORK/sim" "$WORK/uart.v" fpga/tb_uart_baud.sv
    "$ROOT/scripts/runsim.sh" --tail 0 -- vvp -n "$WORK/sim" \
      || { echo "FAIL uart-baud: $(basename "$(dirname "$top")") at host ${ppm} ppm"; exit 1; }
  done
  printf 'PASS uart-baud: %-18s %6s MHz / %3s clocks per bit, host -2%% / 0 / +2%%\n' "$(basename "$(dirname "$top")")" "$mhz" "$div"
  n=$((n+1))
done
(( n > 0 )) || { echo "FAIL uart-baud: no generated board image carries a UART line -- run make bind"; exit 1; }
