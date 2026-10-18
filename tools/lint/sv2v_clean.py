#!/usr/bin/env python3
"""sv2v_clean.py -- drop the package constants sv2v copies into a module and
then leaves unreferenced (Verilator UNUSEDPARAM). Reads Verilog on stdin,
writes it to stdout. A one-line localparam is dropped only if its name
appears nowhere else in its module, so the design cannot change.

The same filter is embedded in tt/tile/src/regen.sh, because the tile is a
standalone repository; keep the two in step.
"""
import re
import sys

src = sys.stdin.read()
out = []
for mod in re.split(r"(?m)^(?=module )", src):
    keep = []
    for line in mod.split("\n"):
        m = re.match(r"\s*localparam (?:\[[^\]]*\] )?(\w+) = [^;]+;\s*$", line)
        if m and len(re.findall(r"\b" + m.group(1) + r"\b", mod)) == 1:
            continue
        keep.append(line)
    out.append("\n".join(keep))
sys.stdout.write("".join(out))
