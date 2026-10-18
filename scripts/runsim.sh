#!/usr/bin/env bash
# runsim.sh -- run a simulation and FAIL if it failed, whatever its exit code.
#
#   scripts/runsim.sh [--tail N] [--show REGEX] [--expect REGEX] -- vvp -n sim
#
# WHY (audit R5 follow-up, 2026-10-11): sv2v translates $fatal(1) into
# $finish(1), and for Icarus the argument of $finish is a verbosity level, not
# an exit code. So every testbench run through sv2v exits 0 even when it
# prints FAIL, and `vvp ... | tail -2` under pipefail passes. Nothing had
# failed silently yet, but nothing could have failed at all. This wrapper
# decides from the output as well as the exit code:
#   * a non-zero exit fails,
#   * a line starting FAIL, a "Fatal [" report, or "$finish(1)" fails,
#   * no line matching --expect (default ^PASS) fails.
#   * a run longer than RUNSIM_TIMEOUT seconds (default 900) is killed and
#     fails: a broken design that HANGS a testbench without a watchdog (the
#     2026-10-11 self-test found tb_mom_system waits for ever on a dispatcher
#     that never retires) must turn the build red, not stall it for hours.
# The whole log is kept on failure. Default output: the last 2 lines.
set -uo pipefail
TAIL=2; SHOW=""; EXPECT='^PASS'
while [[ $# -gt 0 && "$1" != "--" ]]; do
  case "$1" in
    --tail) TAIL="$2"; shift 2 ;;
    --show) SHOW="$2"; shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    *) echo "runsim: unknown option $1"; exit 2 ;;
  esac
done
[[ "${1:-}" == "--" ]] && shift
[[ $# -gt 0 ]] || { echo "runsim: no command"; exit 2; }
LOG="$(mktemp "${TMPDIR:-/tmp}/runsim.XXXXXX.log")"
timeout --kill-after=10 "${RUNSIM_TIMEOUT:-900}" "$@" > "$LOG" 2>&1; rc=$?
(( rc == 124 || rc == 137 )) && echo "runsim: killed after ${RUNSIM_TIMEOUT:-900} s" >> "$LOG"
if [[ -n "$SHOW" ]]; then grep -E "$SHOW" "$LOG" || true; else tail -n "$TAIL" "$LOG"; fi
why=""
(( rc == 0 )) || why="exited $rc"
(( rc == 124 || rc == 137 )) && why="did not finish in ${RUNSIM_TIMEOUT:-900} s (hung?)"
[[ -z "$why" ]] && grep -qE '^FAIL|Fatal \[|\$finish\(1\)' "$LOG" && why="printed a failure"
[[ -z "$why" ]] && ! grep -qE "$EXPECT" "$LOG" && why="never printed a line matching $EXPECT"
if [[ -n "$why" ]]; then
  grep -nE '^FAIL|Fatal \[|ERROR|Error' "$LOG" | head -8
  echo "FAIL runsim: $* $why (full log: $LOG)"
  exit 1
fi
rm -f "$LOG"
