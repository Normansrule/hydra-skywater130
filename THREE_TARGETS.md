# HYDRA-130: three targets from one repository

Session 179. Everything with a number beside it was measured in this session
with the tools named; everything else is marked as a plan or a hypothesis.

The three targets are the same design at three scales:

| | what it is | status |
|---|---|---|
| **TT-A v2** | the Mathematical Operation MUX (MOM) on a Tiny Tapeout tile, now with its whole interface reachable | built, 17 tests, 14/15 sabotages caught |
| **sky130 full chip** | CPU, SIMD, TPU, NTT and crypto behind the MOM, on a padframe of its own | planned here; needs the `~/hydra` sources |
| **FPGA** | the same RTL on any board, driven from a PC | built for three boards, placed and routed on ECP5 |

---

## 1. Tiny Tapeout: what v2 adds and why

v1 (session 144) reaches the MOM through 24 pins by shifting a 128-bit
descriptor serially. To do that it ties off every input it cannot reach: the
parameter ROM write port (its own comment calls retuning "a v2 feature"),
`disp_accept` (no back-pressure), the fence, and the calibration controls. It
reads back a 4-bit margin.

Those tie-offs remove the two claims that most need silicon evidence: that the
dispatch policy can be **retuned after tapeout**, and that the calibration loop
**converges against real latencies**.

v2 keeps v1 exactly and adds a second personality:

- **LEGACY** (default) is v1's pin map. Selected whenever `ui_in[7:4] != 0xA`
  during reset, which includes every v1 test and the demoboard default.
- **REGISTER** is selected by holding `ui_in[7:4] = 0xA` through reset. Then
  `ui_in[2:0]` are chip-select, data-in and clock of a Serial Peripheral
  Interface (SPI) target, `uo_out[0]` is data-out, and a 14-register map
  reaches all of `mom_top`: descriptor, GO with a real handshake, completion,
  fence, parameter rows, calibration freeze and reset, back-pressure, the full
  32-bit margin, the descriptor as dispatched, the tag bitmap, and the
  calibration update counter.

The strap is sampled on every clock while reset is low, so it needs no reset
value of its own and is stable from the first cycle after reset.

### Measured

| check | result |
|---|---|
| `src/project.v` against `regen.sh` (sv2v 0.0.13) | identical before and after the change |
| v1's 8 tests, unmodified, against v2 | 8/8 pass |
| v1 RTL vs v2 side by side, random pins | 400,000 cycles, 3,118 random resets, 69,159 dispatch cycles, 0 differences |
| new register-mode tests | 9/9 pass (17 total in the tile suite) |
| `hydra_tt_spi` formal proof (yices, k-induction) | proved, cover reachable |
| sabotage campaign (`test/mutate_sim.py`) | 14 of 15 caught by the test named for each |

What the register mode showed that v1 could not:

- **Retuning moves the decision.** TPU setup cost 64 → 4000 sends the 8×8×8
  multiply to SIMD; restoring the row restores the TPU; `PARAM_LOCK` makes the
  same write inert.
- **The calibration loop closes.** With completions arriving far later than
  predicted, the margin falls 136 → 1 over 18 dispatches and the 19th chooses
  SIMD. That is the roofline model correcting itself, end to end.
- **Real margins are small**: 32 for 4×4×4, 145 for 8×8×8.

### A bug in v1's margin nibble

```
wire [3:0] margin_nib = (obs_margin[COST_W-1:12] != '0) ? 4'hF : obs_margin[15:12];
```

Bits 15:12 are inside the range just tested, so the nibble can only ever be 0
or F. Both session 144 runs logged 0, and with real margins of 32 and 145 it
would read 0 even after the obvious fix. v2 therefore:

- fixes legacy to saturate on `[31:16]`, which is what the comment intended;
- uses `1 + floor(log2(margin))` for the register personality's pins (32 → 6,
  145 → 8) and puts the full 32-bit value in `RESULT`.

### The one sabotage that survived

Removing the gate that keeps legacy pin traffic out of the SPI block
(`.csn_i(~reg_mode | ui_in[2])`) survives the whole suite. That is correct, not
a weak test: every register output is gated by `reg_mode` at the `mom_top`
instance, and `reg_mode` can only change while reset is asserted, which also
clears the register block. The gate is isolation, not behaviour. It stays, and
`mutate_sim.py` records why it is not a mutation target.

### Area and tiles — MEASURED

Mapped to the sky130 high-density standard cells with yosys and abc
(`tools/sky130_area.sh`, which reproduces this):

| build | cell area | cells | density at 3x4 | at 4x4 or 8x2 |
|---|---|---|---|---|
| v1 (`b179c6b`) | 135,203 um2 | 22,753 | 62.5% | 46.9% |
| v2 | 194,647 um2 | 28,183 | **89.9%** | 67.5% |
| v2 without the LASTWD readback | 178,262 um2 | — | 82.4% | 61.8% |

A tile is 167 x 108 um, so `3x4` is 216,432 um2 and `4x4` (or `8x2`, the same
area) is 288,576 um2.

**v2 does not fit `tiles: "3x4"`.** It is 44% larger than v1, which itself sat
near 62% density there. Dropping the 128-bit captured descriptor saves only
8%, so it does not rescue 3x4 and is not worth the lost readback.

**Set `tiles: "4x4"` (or `"8x2"`).** v2 then sits at 67.5%, close to the
density v1 hardened at, with headroom for the clock tree.

These are yosys+abc numbers, not OpenLane numbers: OpenLane synthesises
differently and then adds buffering, clock tree and fill, so the absolute
figures read low. The RATIO is the trustworthy part. Confirm with a real
harden before submitting. Before submitting:

1. harden v2 at `tiles: "3x4"` and read the utilisation;
2. if `4x4` is refused by the shuttle, `8x2` has identical area;
3. do not hand-edit the floorplan to squeeze it in — that is the ASICirific
   failure the v1 header documents.

Tiny Tapeout's current template allows 1x1 through 8x2 and describes a tile as
about 167 × 108 µm; ChipFoundry sky130 shuttles have also allowed 4-tile-high
designs, which is what `3x4` uses. Confirm the allowed sizes for the shuttle
you submit to.

---

## 2. The sky130 full chip

### The blocked item first

`./tools/verify_all.sh soc` fails at `global_route`. The leading hypothesis,
from the numbers in the handoff, is that the die is too small rather than the
router being at fault:

| block | cell area |
|---|---|
| ecdsa_top | 2.329 mm² |
| tpu_top | 0.842 mm² |
| core_pipe | 0.355 mm² |
| mom_top | 0.337 mm² |
| core_mini | 0.125 mm² |
| small blocks (×4) | ~0.032 mm² |
| data RAM (flop array) | 0.930 mm² |
| **total, before the GPU and the remaining peripherals** | **≈ 4.95 mm²** |

At `SOC_UTIL` 0.35 that needs about 14 mm². The handoff's own arithmetic
("0.93 mm², about 9% of the die budget") implies a budget near 10.3 mm², which
is Caravel's user area. If the die is fixed at that size, no utilisation
setting will route it, and lowering `SOC_UTIL` makes congestion worse, not
better, when the die does not grow with it.

This is a hypothesis because the table may be core area rather than cell area.
`/tmp/verify_all_soc_0.log` and the `DIE_AREA` line in the SoC config settle it
in one look.

### What exists now

`sky130/rtl/hydra_openframe_top.sv` is the chip: the real 44-pad OpenFrame
interface, the proved pad multiplexer on the 24 functional pads, a bring-up
sequence, and the tile as its first macro. `sky130/tb/tb_openframe.sv` drives
it through the pads and checks that nothing is driven during reset, that the
inert personality holds when the connect strap is low, that the tile answers
over SPI once connected, and that the personality then locks.

That bench earned its place immediately: the first run read an identity of
zero. The tile samples its own personality strap while ITS reset is low, and
the pad multiplexer was still inert at that moment, so the tile booted into
the wrong personality with the pins sitting right there. The fix is ordering —
hold the tile in reset until the pads are connected and locked. On silicon
that would have been a bring-up session spent on an oscilloscope.

Each SoC block joins beside the tile as its sources arrive.

### Frame choice

ChipFoundry's OpenFrame provides only a padframe — no integrated SoC — with a
15 mm² user area and 44 GPIOs; its template's wrapper config hardens a core
area of 3086.63 × 4686.63 µm, which is 14.47 mm². Double-Wide OpenFrame gives
roughly 32 mm² with the same interface. Caravel Mini is ~2 mm² with 36 GPIOs.
Standard chipIgnite pricing is $14,950 per project including 100 packaged
parts.

Recommendation:

1. **OpenFrame, not Caravel.** The SoC is its own processor complex; the
   Caravel management core buys nothing here and costs two thirds of the area.
2. **44 pads for 45 signals.** `common/rtl/hydra_padmux.sv` (proved,
   8/8 mutations killed) resolves that: give the pads that differ between
   bring-up and mission modes two functions each, reset to all-inputs, and lock
   the selection before the keystore is used. `CF_gpio_config` from ChipFoundry
   handles the pad control bits; the muxed pads must be mode 5 (bidirectional)
   since the direction changes at runtime.
3. **Harden per block, not flat.** OpenLane running twelve hours without
   placing `ecdsa_top` (session 178) and `global_route` failing at the SoC are
   both symptoms of a flat 400k-cell place-and-route. The OpenFrame template's
   own flow hardens each macro separately and then assembles them with
   `VERILOG_FILES_BLACKBOX`, `EXTRA_LEFS`, `EXTRA_GDS_FILES` and a
   `macro.cfg` placement. Each block in the handoff's table already has its
   own PAR run, so most of that work exists.

### The MOM is the mux, and it needs a crossbar

The MOM decides; nothing in the SoC yet routes work to the engine it chose.
`mom_top`'s dispatch port (`disp_valid/accept/engine/tag/wd`) is the interface
to an engine crossbar that does not exist. That crossbar is the piece that
turns five engines plus a dispatcher into a machine:

- one target port per engine (CPU, SIMD, TPU, NTT, crypto), each with the same
  valid/accept/tag handshake the MOM already speaks;
- completions back to `comp_valid/comp_tag`, which is what closes the
  calibration loop on real silicon rather than on a host's completion writes;
- the same arbitration pattern `ecdsa_top` used in session 174 — owner latched
  at GO, released on completion — which is already proven in this project.

Suggested order for the chip, folding into the handoff's own list: SoC die
number first, then the crossbar (it is what makes the TPU and GPU reachable),
then the SHE CMAC path, then `trng_source`/`trng_pool`.

---

## 3. FPGA

Purpose: a bench platform for the calibration loop with real latencies, and a
rehearsal of demoboard bring-up before silicon returns.

### Which board to buy

**Lattice ECP5 Evaluation Board, LFE5UM5G-85F-EVN** — DigiKey, in stock,
around $99-$159 depending on distributor
(<https://www.digikey.com/en/products/detail/lattice-semiconductor-corporation/LFE5UM5G-85F-EVN/9553907>).

Why this one, measured rather than assumed:

| | |
|---|---|
| fits | 14,360 of 83,640 LUTs (17%), 3,742 flops, 10 multipliers |
| speed | Fmax 31.85 MHz, passing at the board's 12 MHz oscillator, no PLL needed |
| toolchain | fully open: yosys, nextpnr-ecp5, ecppack. No vendor licence, no registration |
| headroom | 83k LUTs leaves room for the SoC blocks as they come across |

The alternatives, and why not:

- **Arty A7-35T** was the obvious choice and is **retired** — Digilent no longer
  produces it. The A7-100T remains, at around $299, and needs Vivado.
- **Cmod A7-35T** ($99, DigiKey) fits the tile and is the cheapest Xilinx route,
  but Vivado is a ~50 GB install and the generated `build.tcl` has never been
  run by anyone yet.
- **iCEBreaker / iCE40 UP5K** cannot hold the tile: 8,622 LUT4 needed against
  5,280 available. Measured, not estimated.
- **Tang Nano 20K** ($30, Amazon) has 20,736 LUT4 — the tile would sit near 70%,
  and `nextpnr-himbaechel` is not packaged for Ubuntu. Workable, tight, more
  setup.
- **ULX3S** is the same ECP5 device and is supported here, but it is a
  Crowd Supply / Mouser item rather than DigiKey or Amazon.

`plans/ecp5-evn.yaml` builds for it. One board note: the serial pins (P2/P3)
sit on the FTDI channel-B header — check jumpers against the board user guide,
or wire a 3.3 V USB-serial adapter to them.

### Boards

`fpga/boards/*.yaml` are generated from the vendors' own constraint files by
`tools/import_boards.py`, which records each file's URL and SHA-256 and has a
`check` mode that fails on drift. Pins typed from memory are how a board file
goes wrong: in this session the iCEBreaker's second Pmod header was
misremembered and the vendor file corrected it.

Ten boards: Arty A7-35 and A7-100, Basys 3, Nexys A7-100T, Nexys Video,
Genesys 2, iCEBreaker, ULX3S-85F, Tang Nano 20K, DE10-Lite. Adding one means
adding a profile and pointing at its constraint file.

Each pin carries a role (LEDs output-only, switches input-only, headers
bidirectional) so the generator refuses a plan that, for example, maps a
serial input onto an LED — which it did catch during this session.

### Measured fit

| | |
|---|---|
| iCE40 (yosys `synth_ice40`) | 8,622 LUT4 + 3,051 flops — **does not fit** the iCEBreaker's 5,280 LUTs |
| ECP5-85F (yosys + nextpnr) | 14,360 LUTs (17%), 3,742 flops (4%), 10 multipliers, 21 I/O |
| ECP5-85F achieved Fmax | **15.41 MHz** (yosys 0.33 / nextpnr 0.6); **23.94 MHz** on yosys 0.52 / nextpnr 0.9; **31.85 MHz** on the ECP5 evaluation board build |

So the smallest open-toolchain board that can host the tile is an ECP5. And
since Fmax is 15.41 MHz, a 25 MHz oscillator cannot clock it directly: the
ULX3S plan asks for 12.5 MHz and `tools/pllcalc.py` sets the PLL to reach it.

That rule — **never exceed the requested frequency** — is why the solver
refuses a 16 MHz output from a 12 MHz input on iCE40: the phase detector must
run at 12 MHz, so the VCO is a multiple of 12 and nothing lands on 16. `icepll`
answers 15.938 MHz, below the family's 16 MHz floor. The solver refuses with an
error that says what to do instead. It is checked against `icepll`, `ecppll`
and `gowin_pll` (25 tests).

### Driving it

`fpga/rtl/hydra_fpga_tt_harness.sv` puts the tile behind the board's USB-serial
port with a command set (SPI frame, tile reset with personality select, direct
pin level, single-clock pin pulse). The single-clock pulse exists because the
legacy personality shifts one descriptor bit per clock while `shift` is high, so
a level held across a serial round trip would shift hundreds of bits.

`tb_fpga_harness.sv` drives that protocol and checks both personalities,
including the crossover, a retune, and that parameters do not survive a tile
reset. It caught a real bug: in the legacy personality the SPI idle pattern
(chip-select high) sits on `ui_in[2]`, which is legacy's `go` pin, and
dispatched whatever was in the shift register the moment reset released.

`tools/hydra_host.py` is the PC side: `selftest` runs identity, crossover,
retune and the calibration loop over the serial port and prints pass or fail.

---

## 4. Running all of it

```bash
make verify          # everything below, in order
```

| step | what it proves |
|---|---|
| `make padmux` | pad mux vs an independent model, proof, mutations |
| `make tile` | the tile's 17 cocotb tests (both personalities) |
| `make diff` | v2 legacy is v1, pin for pin, on random stimulus |
| `make harness` | the PC protocol end to end |
| `make tools` | PLL solver against the vendors' calculators; host encodings |
| `make boards` | board files still match their vendor sources |
| `make bind` | generated board tops still match the plans and the RTL |
| `make mutate` | every test can fail (formal and simulation) |

Nothing in here weakens a test to make it pass. Where a check could not be run
in this environment — tile area, Vivado and Quartus builds, the slow-corner
timing read — it is named as not run rather than assumed.
