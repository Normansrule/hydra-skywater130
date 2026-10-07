#!/usr/bin/env bash
# ntt_area.sh -- sky130 cell area of the butterfly engine, per modulus.
# Same method as sky130_area.sh (yosys + abc against the sky130 typical-corner
# library). Its multipliers made synthesis outlast the build environment that
# wrote this, so it is meant to run on a desktop:   make area-ntt
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${SKY130_LIB:-$ROOT/fpga/vendor_refs/sky130_fd_sc_hd__tt_025C_1v80.lib}"
if [[ ! -f "$LIB" ]]; then
  mkdir -p "$(dirname "$LIB")"
  curl -fsSL -o "$LIB" "https://raw.githubusercontent.com/efabless/skywater-pdk-libs-sky130_fd_sc_hd/master/timing/sky130_fd_sc_hd__tt_025C_1v80.lib"
fi
# q=8380417 (ML-DSA) takes far longer than the other two; QS=8380417 make
# area-ntt runs it alone. Progress goes to stderr so a long run is visible.
for Q in ${QS:-12289 3329 8380417}; do
  t0=$(date +%s)
  echo "ntt q=$Q: synthesising ($(date +%H:%M:%S))..." >&2
  sv2v --define=HYDRA_NTT_Q=$Q "$ROOT"/engines/ntt/rtl/*.sv > /tmp/ntt_area_$Q.v
  yosys -q -p "read_verilog /tmp/ntt_area_$Q.v; synth -top ntt_top -flatten;
    dfflibmap -liberty $LIB; abc -liberty $LIB; opt_clean; tee -o /tmp/ntt_area_$Q.txt stat -liberty $LIB" >/dev/null
  cells=$(grep -m1 -E "Number of cells" /tmp/ntt_area_$Q.txt | awk '{print $NF}')
  area=$(grep -m1 -E "Chip area" /tmp/ntt_area_$Q.txt | awk '{print $NF}')
  printf "ntt q=%-8s %7s cells  %12s um^2\n" "$Q" "$cells" "$area"
  echo "ntt q=$Q: done in $(( $(date +%s) - t0 )) s" >&2
done
