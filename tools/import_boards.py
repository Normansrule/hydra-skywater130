#!/usr/bin/env python3
"""
import_boards.py -- build fpga/boards/*.yaml from the vendors' own pin files.

WHY
  A pin table typed from memory is an anchor with no source: nothing keeps it
  honest, and a wrong pin is found on the bench, not in CI. During session 179
  exactly that happened -- the iCEBreaker PMOD2 pins recalled from memory were
  wrong, and the vendor file caught it. So every pin, and every I/O standard,
  is parsed out of the vendor's constraint file, and the file's URL and
  SHA-256 are recorded in the YAML. `--check` re-parses and fails on drift.

  What cannot be parsed (oscillator frequency, which button is reset and its
  polarity, LED polarity, device capacity) lives in PROFILES below, each with
  a note saying where it came from. Items marked VERIFY were not confirmed
  against a schematic in this session.

Usage:
  python3 import_boards.py fetch        download vendor files into vendor_refs/
  python3 import_boards.py build        write boards/*.yaml
  python3 import_boards.py check        rebuild in memory, diff against boards/
"""
import hashlib
import pathlib
import re
import sys
import urllib.request

import yaml

HERE = pathlib.Path(__file__).resolve().parent
FPGA = HERE.parent / "fpga"
REFS = FPGA / "vendor_refs"
BOARDS = FPGA / "boards"

# Every source is pinned to the upstream COMMIT whose content matches the
# recorded SHA-256, never to a branch. On 2026-10-08 litex-boards added a
# connector to lattice_ecp5_evn.py on master; the hash check caught it
# (as designed) and turned every CI run red over a comment upstream. A
# commit URL cannot change, so the build cannot break that way again; to
# take an upstream change, move the commit here on purpose and rebuild.
SOURCES = {
    "Arty-A7-35-Master.xdc":
        "https://raw.githubusercontent.com/Digilent/digilent-xdc/0256a131e11142f9abd3ccaaf0e9a479a616cf2f/Arty-A7-35-Master.xdc",
    "Arty-A7-100-Master.xdc":
        "https://raw.githubusercontent.com/Digilent/digilent-xdc/bb01f62e09a8d8d5e85971aa12cf1d15e0f48207/Arty-A7-100-Master.xdc",
    "Basys-3-Master.xdc":
        "https://raw.githubusercontent.com/Digilent/digilent-xdc/69d35015d4c3a0cb384a964459593cea5260697a/Basys-3-Master.xdc",
    "Nexys-A7-100T-Master.xdc":
        "https://raw.githubusercontent.com/Digilent/digilent-xdc/7583b4e7a6b8178afdb7f9e07f18162c48a89b0d/Nexys-A7-100T-Master.xdc",
    "Nexys-Video-Master.xdc":
        "https://raw.githubusercontent.com/Digilent/digilent-xdc/16e3b34a3d43c1d203e935038014a208f86c7fde/Nexys-Video-Master.xdc",
    "Genesys-2-Master.xdc":
        "https://raw.githubusercontent.com/Digilent/digilent-xdc/19d1a3be934bce54e80a5de2fae4fa6e396a3691/Genesys-2-Master.xdc",
    "icebreaker.pcf":
        "https://raw.githubusercontent.com/icebreaker-fpga/icebreaker-verilog-examples/92f9dae53460b6c98c28e0537ba1584f0051b6a8/icebreaker/icebreaker.pcf",
    "ulx3s_v20.lpf":
        "https://raw.githubusercontent.com/emard/ulx3s/ca5fa288bc64c4fd83302ade4adae811e53bd451/doc/constraints/ulx3s_v20.lpf",
    "tangnano20k_nestang.cst":
        "https://raw.githubusercontent.com/sipeed/TangNano-20K-example/e23949a0a77381b94960cbc4e97a7c5e5ba8d222/nestang/src/nestang.cst",
    "tangnano20k_flow_led.cst":
        "https://raw.githubusercontent.com/sipeed/TangNano-20K-example/2589f80ac3f5e11a96a4481bce711963757b126d/led/flow_led/src/flow_led.cst",
    "lattice_ecp5_evn.py":
        "https://raw.githubusercontent.com/litex-hub/litex-boards/7a211c89b9a94ec1044056d28cf6e22e74a15e8b/litex_boards/platforms/lattice_ecp5_evn.py",
    "de10-lite.qsf":
        "https://raw.githubusercontent.com/f32c/f32c/f7a90a0c4343ca72a79c490562d4542929abcc86/rtl/proj/altera/de10-lite/xram_sdram_vector/de10-lite.board",
}

# --------------------------------------------------------------------------- parsers
def parse_xdc(text):
    pins = {}
    pat = re.compile(r"PACKAGE_PIN\s+(\S+)\s+IOSTANDARD\s+(\S+).*?get_ports\s*\{?\s*([A-Za-z_0-9\[\]]+)\s*\}?\s*\]")
    for line in text.splitlines():
        m = pat.search(line)
        if m:
            pins[m.group(3)] = {"pin": m.group(1), "iostandard": m.group(2)}
    return pins


def parse_pcf(text):
    pins = {}
    for line in text.splitlines():
        m = re.match(r"\s*set_io\s+(?:-\S+\s+)*(\S+)\s+(\S+)", line)
        if m:
            pins[m.group(1)] = {"pin": m.group(2)}
    return pins


def parse_lpf(text):
    pins = {}
    for line in text.splitlines():
        m = re.match(r'\s*LOCATE\s+COMP\s+"([^"]+)"\s+SITE\s+"([^"]+)"', line)
        if m:
            pins[m.group(1)] = {"pin": m.group(2)}
        m = re.match(r'\s*IOBUF\s+PORT\s+"([^"]+)"(.*);', line)
        if m and m.group(1) in pins:
            t = re.search(r"IO_TYPE=(\S+)", m.group(2))
            if t:
                pins[m.group(1)]["iostandard"] = t.group(1)
    return pins


def parse_cst(text):
    pins = {}
    for line in text.splitlines():
        m = re.match(r'\s*IO_LOC\s+"([^"]+)"\s+(\S+);', line)
        if m:
            pins[m.group(1)] = {"pin": m.group(2)}
    return pins


def parse_qsf(text):
    pins = {}
    for line in text.splitlines():
        m = re.match(r"\s*set_location_assignment\s+PIN_(\S+)\s+-to\s+(\S+)", line)
        if m:
            pins[m.group(2)] = {"pin": m.group(1)}
    return pins


def parse_litex(text):
    """LiteX platform files are the usual source of truth for boards whose
    vendor ships no constraint file. Entries look like
        ("user_led", 3, Pins("A18"), IOStandard("LVCMOS25")),
    and Subsignals carry their own Pins/IOStandard."""
    pins, io = {}, {}
    name = None
    index = None
    for line in text.splitlines():
        m = re.match(r'\s*\("([A-Za-z_0-9]+)",\s*(\d+),', line)
        if m:
            name, index = m.group(1), int(m.group(2))
        sub = re.search(r'Subsignal\("([A-Za-z_0-9]+)",\s*Pins\("([^"]+)"\)', line)
        std = re.search(r'IOStandard\("([^"]+)"\)', line)
        direct = re.match(r'\s*\("([A-Za-z_0-9]+)",\s*(\d+),\s*Pins\("([^"]+)"\)', line)
        if direct:
            key = f"{direct.group(1)}{direct.group(2)}"
            pins[key] = {"pin": direct.group(3)}
            if std:
                pins[key]["iostandard"] = std.group(1)
        elif sub and name is not None:
            key = f"{name}{index}_{sub.group(1)}"
            pins[key] = {"pin": sub.group(2)}
            if std:
                pins[key]["iostandard"] = std.group(1)
    # A Subsignal without its own IOStandard inherits the group's trailing one.
    return pins


PARSERS = {".py": parse_litex, ".xdc": parse_xdc, ".pcf": parse_pcf, ".lpf": parse_lpf,
           ".cst": parse_cst, ".qsf": parse_qsf}

# --------------------------------------------------------------------------- profiles
# groups: logical name -> list of vendor port names (bit order = list order)
def seq(fmt, n, start=0):
    return [fmt.format(i) for i in range(start, start + n)]


def pmod12(h):
    """Nexys A7 names Pmod pins by connector pin number: 1-4 and 7-10."""
    return [f"{h}[{i}]" for i in (1, 2, 3, 4, 7, 8, 9, 10)]


XILINX_DIGILENT_NOTE = "clock/reset/LED polarity: Digilent reference manual"

PROFILES = {
    "arty-a7-35": dict(
        refs=["Arty-A7-35-Master.xdc"], vendor="xilinx7", family="artix7",
        device="xc7a35ticsg324-1L", luts=20800, lut_kind="LUT6",
        clock=dict(port="CLK100MHZ", hz=100_000_000),
        reset=dict(port="ck_rst", active="low", note="red RESET button; VERIFY on your board revision"),
        led_active="high",
        groups=dict(led=seq("led[{}]", 4), sw=seq("sw[{}]", 4), btn=seq("btn[{}]", 4),
                    ja=seq("ja[{}]", 8), jb=seq("jb[{}]", 8), jc=seq("jc[{}]", 8), jd=seq("jd[{}]", 8)),
        uart=dict(tx="uart_rxd_out", rx="uart_txd_in"), note=XILINX_DIGILENT_NOTE),
    "arty-a7-100": dict(
        refs=["Arty-A7-100-Master.xdc"], vendor="xilinx7", family="artix7",
        device="xc7a100tcsg324-1", luts=63400, lut_kind="LUT6",
        clock=dict(port="CLK100MHZ", hz=100_000_000),
        reset=dict(port="ck_rst", active="low", note="VERIFY on your board revision"),
        led_active="high",
        groups=dict(led=seq("led[{}]", 4), sw=seq("sw[{}]", 4), btn=seq("btn[{}]", 4),
                    ja=seq("ja[{}]", 8), jb=seq("jb[{}]", 8), jc=seq("jc[{}]", 8), jd=seq("jd[{}]", 8)),
        uart=dict(tx="uart_rxd_out", rx="uart_txd_in"), note=XILINX_DIGILENT_NOTE),
    "basys3": dict(
        refs=["Basys-3-Master.xdc"], vendor="xilinx7", family="artix7",
        device="xc7a35tcpg236-1", luts=20800, lut_kind="LUT6",
        clock=dict(port="clk", hz=100_000_000),
        reset=dict(port="btnC", active="high", note="no dedicated reset button; centre button used"),
        led_active="high",
        groups=dict(led=seq("led[{}]", 16), sw=seq("sw[{}]", 16),
                    ja=seq("JA[{}]", 8), jb=seq("JB[{}]", 8), jc=seq("JC[{}]", 8)),
        uart=dict(tx="RsTx", rx="RsRx"), note=XILINX_DIGILENT_NOTE),
    "nexys-a7-100t": dict(
        refs=["Nexys-A7-100T-Master.xdc"], vendor="xilinx7", family="artix7",
        device="xc7a100tcsg324-1", luts=63400, lut_kind="LUT6",
        clock=dict(port="CLK100MHZ", hz=100_000_000),
        reset=dict(port="CPU_RESETN", active="low"),
        led_active="high",
        groups=dict(led=seq("LED[{}]", 16), sw=seq("SW[{}]", 16),
                    ja=pmod12("JA"), jb=pmod12("JB"), jc=pmod12("JC"), jd=pmod12("JD")),
        uart=dict(tx="UART_RXD_OUT", rx="UART_TXD_IN"), note=XILINX_DIGILENT_NOTE),
    "nexys-video": dict(
        refs=["Nexys-Video-Master.xdc"], vendor="xilinx7", family="artix7",
        device="xc7a200tsbg484-1", luts=134600, lut_kind="LUT6",
        clock=dict(port="clk", hz=100_000_000),
        reset=dict(port="cpu_resetn", active="low"),
        led_active="high",
        groups=dict(led=seq("led[{}]", 8), sw=seq("sw[{}]", 8),
                    ja=seq("ja[{}]", 8), jb=seq("jb[{}]", 8), jc=seq("jc[{}]", 8)),
        uart=dict(tx="uart_rx_out", rx="uart_tx_in"), note=XILINX_DIGILENT_NOTE),
    "genesys2": dict(
        refs=["Genesys-2-Master.xdc"], vendor="xilinx7", family="kintex7",
        device="xc7k325tffg900-2", luts=203800, lut_kind="LUT6",
        clock=dict(port_p="sysclk_p", port_n="sysclk_n", hz=200_000_000),
        reset=dict(port="cpu_resetn", active="low", note="VERIFY polarity against the reference manual"),
        led_active="high",
        groups=dict(led=seq("led[{}]", 8), sw=seq("sw[{}]", 8)),
        uart=dict(tx="uart_rx_out", rx="uart_tx_in"), note=XILINX_DIGILENT_NOTE),
    "icebreaker": dict(
        refs=["icebreaker.pcf"], vendor="ice40", family="ice40up",
        device="up5k", package="sg48", luts=5280, lut_kind="LUT4",
        clock=dict(port="CLK", hz=12_000_000),
        reset=dict(port="BTN_N", active="low"),
        led_active="low",
        groups=dict(led=["LEDR_N", "LEDG_N"],
                    pmod1a=["P1A1", "P1A2", "P1A3", "P1A4", "P1A7", "P1A8", "P1A9", "P1A10"],
                    pmod1b=["P1B1", "P1B2", "P1B3", "P1B4", "P1B7", "P1B8", "P1B9", "P1B10"],
                    pmod2=["P2_1", "P2_2", "P2_3", "P2_4", "P2_7", "P2_8", "P2_9", "P2_10"]),
        uart=dict(tx="TX", rx="RX"), note="icebreaker-verilog-examples; LEDs are active low per the _N names"),
    "ulx3s-85f": dict(
        refs=["ulx3s_v20.lpf"], vendor="ecp5", family="ecp5",
        device="LFE5U-85F", package="CABGA381", speed="6", luts=83640, lut_kind="LUT4",
        nextpnr_device="--85k",
        clock=dict(port="clk_25mhz", hz=25_000_000),
        reset=dict(port="btn[0]", active="low", note="BTN_PWRn, 'inverted logic' per the lpf"),
        led_active="high",
        groups=dict(led=seq("led[{}]", 8), btn=seq("btn[{}]", 6, 1),
                    gp=seq("gp[{}]", 28), gn=seq("gn[{}]", 28)),
        uart=dict(tx="ftdi_rxd", rx="ftdi_txd"),
        note="emard/ulx3s lpf. For 12F/25F/45F copy this file and change device/nextpnr_device/luts"),
    "tangnano20k": dict(
        refs=["tangnano20k_flow_led.cst", "tangnano20k_nestang.cst"], vendor="gowin", family="gw2a",
        device="GW2AR-LV18QN88C8/I7", pll_device="GW2A-18 C8/I7", luts=20736, lut_kind="LUT4",
        clock=dict(port="clk", hz=27_000_000),
        reset=dict(port="s1", active="high", note="S1 button; VERIFY polarity against the schematic"),
        led_active="low",
        groups=dict(led=seq("leds[{}]", 6)),
        extra_pins={"uart_tx": {"pin": "69"}, "uart_rx": {"pin": "70"}},
        uart=dict(tx="uart_tx", rx="uart_rx"),
        note="Sipeed examples; UART 69/70 from the Sipeed UART examples; LEDs sink current (active low) VERIFY"),
    "ecp5-evn": dict(
        refs=["lattice_ecp5_evn.py"], vendor="ecp5", family="ecp5",
        device="LFE5UM5G-85F", package="CABGA381", speed="8", luts=83640, lut_kind="LUT4",
        nextpnr_device="--um5g-85k",
        clock=dict(port="clk120", hz=12_000_000),
        reset=dict(port="button_10", active="low",
                   note="button_1 on the board; rst_n (G2) is the FPGA's own reset pin, not a user input"),
        led_active="high",
        groups=dict(led=[f"user_led{i}" for i in range(8)],
                    dip=[f"user_dip_btn{i}" for i in range(1, 9)]),
        uart=dict(tx="serial0_tx", rx="serial0_rx"),
        note="Lattice ECP5 Evaluation Board (LFE5UM5G-85F-EVN). Pins from the LiteX "
             "platform file. The serial pins P2/P3 are on the FTDI channel B header: "
             "check jumpers J38/J39 (see the board user guide) or wire a 3.3 V USB-UART "
             "adapter to them"),
    "de10-lite": dict(
        refs=["de10-lite.qsf"], vendor="intel", family="max10",
        device="10M50DAF484C7G", luts=49760, lut_kind="LE",
        clock=dict(port="MAX10_CLK1_50", hz=50_000_000),
        reset=dict(port="KEY[0]", active="low", note="KEY buttons are active low (Terasic manual)"),
        led_active="high",
        groups=dict(led=seq("LEDR[{}]", 10), sw=seq("SW[{}]", 10), gpio=seq("GPIO[{}]", 36)),
        uart=None,
        note="f32c board file mirrors the Terasic QSF. No USB-UART on this board: use two GPIO pins and a 3.3 V USB-UART adapter"),
}


ROLE = {"led": "out", "sw": "in", "btn": "in", "key": "in"}  # everything else: io


def role_of(group):
    """Can a plan drive this pin, read it, or both? LEDs are output only and
    switches input only; headers are bidirectional. Without this a plan can
    map a UART input onto an LED and nothing complains until the bench."""
    return ROLE.get(group, "io")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_one(name, prof):
    raw = {}
    prov = []
    for ref in prof["refs"]:
        path = REFS / ref
        if not path.exists():
            raise SystemExit(f"{name}: missing {path}; run `import_boards.py fetch`")
        raw.update(PARSERS[path.suffix](path.read_text()))
        prov.append({"file": ref, "url": SOURCES[ref], "sha256": sha(path)})
    raw.update(prof.get("extra_pins", {}))

    def take(port):
        if port not in raw:
            raise SystemExit(f"{name}: port {port!r} not found in {prof['refs']}")
        return dict(raw[port])

    pins = {}
    for grp, ports in prof["groups"].items():
        for i, port in enumerate(ports):
            pins[f"{grp}[{i}]"] = take(port) | {"vendor_name": port, "role": role_of(grp)}
    clock = dict(prof["clock"])
    for k in ("port", "port_p", "port_n"):
        if k in clock:
            clock[k.replace("port", "pin")] = take(clock[k])
    reset = dict(prof["reset"]) | {"pin": take(prof["reset"]["port"])}
    uart = None
    if prof.get("uart"):
        # The UART pins are named from the FPGA's point of view: uart_tx is the
        # pin the FPGA drives. Vendor files name them inconsistently (Digilent
        # calls the FPGA output uart_rxd_out), so the mapping is fixed here and
        # the vendor name is kept beside it.
        uart = {"tx": take(prof["uart"]["tx"]) | {"vendor_name": prof["uart"]["tx"]},
                "rx": take(prof["uart"]["rx"]) | {"vendor_name": prof["uart"]["rx"]}}
        pins["uart_tx"] = uart["tx"] | {"role": "out"}
        pins["uart_rx"] = uart["rx"] | {"role": "in"}

    out = {k: prof[k] for k in ("vendor", "family", "device", "package", "speed",
                                "pll_device", "nextpnr_device", "luts", "lut_kind",
                                "led_active", "note") if k in prof}
    out.update(name=name, clock=clock, reset=reset, uart=uart, pins=pins, provenance=prov)
    return out


def render(name, board):
    head = (f"# GENERATED by tools/import_boards.py from vendor constraint files.\n"
            f"# Do not edit pins here; edit PROFILES and rebuild. `check` detects drift.\n")
    return head + yaml.safe_dump(board, sort_keys=False, width=120)


def main(cmd):
    if cmd == "fetch":
        REFS.mkdir(parents=True, exist_ok=True)
        for f, url in SOURCES.items():
            with urllib.request.urlopen(url, timeout=30) as r:
                (REFS / f).write_bytes(r.read())
            print("fetched", f)
        return
    BOARDS.mkdir(parents=True, exist_ok=True)
    bad = 0
    for name, prof in PROFILES.items():
        text = render(name, build_one(name, prof))
        path = BOARDS / f"{name}.yaml"
        if cmd == "build":
            path.write_text(text)
            print(f"wrote {path.name}: {len(yaml.safe_load(text)['pins'])} pins")
        elif cmd == "check":
            if not path.exists() or path.read_text() != text:
                print(f"DRIFT {path.name}")
                bad += 1
    if cmd == "check":
        if bad:
            sys.exit(1)
        print(f"boards: {len(PROFILES)} files match their vendor sources")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build")
