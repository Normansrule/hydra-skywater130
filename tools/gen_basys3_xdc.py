#!/usr/bin/env python3
"""
gen_basys3_xdc.py -- constraints for a Basys 3 design, derived from Digilent's
own master file by uncommenting exactly the lines whose port names the design
uses. Nothing is retyped, so no pin can be mistyped.

Digilent's Basys-3-Master.xdc ships with every line commented out; a design
"turns on" the pins it uses. This does that mechanically, for the ports the
top module actually declares, and fails if the design names a port Digilent's
file does not have.

    python3 tools/gen_basys3_xdc.py fpga/rtl/hydra_basys3_selftest.sv out.xdc
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MASTER = ROOT / "fpga/boards/basys3/Basys-3-Master.xdc"

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rtl = src.read_text()
start = re.search(r"^\s*module\s", rtl, re.M).start()
hdr = rtl[start:rtl.index(");", start)]
ports = set(re.findall(r"\b(clk|btn[CUDLR]|sw|led|seg|dp|an|RsRx|RsTx)\b", hdr))

kept, seen = [], set()
for line in MASTER.read_text().splitlines():
    m = re.search(r"get_ports\s*\{?\s*([A-Za-z_]+)", line)
    if m and m.group(1) in ports:
        kept.append(line.lstrip("#").lstrip())
        seen.add(m.group(1))
    elif m is None and "create_clock" in line and "clk" in ports:
        kept.append(line.lstrip("#").lstrip())

missing = ports - seen
if missing:
    print(f"gen_basys3_xdc: the design uses ports Digilent's file does not define: {sorted(missing)}")
    sys.exit(1)

# Configuration settings Digilent's file also carries, needed for a clean bitstream.
kept += ["set_property CONFIG_VOLTAGE 3.3 [current_design]",
         "set_property CFGBVS VCCO [current_design]"]
out.write_text("# Generated from fpga/boards/basys3/Basys-3-Master.xdc by tools/gen_basys3_xdc.py.\n"
               "# Do not edit: change the design's ports, then regenerate.\n" + "\n".join(kept) + "\n")
print(f"gen_basys3_xdc: {len(kept)} constraint lines for ports {sorted(ports)}")
