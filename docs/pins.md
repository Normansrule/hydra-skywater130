# HYDRA-130 pins: every pin, every target

This page lists every pin of the two silicon targets, including power and ground, and what each one does. The register details live in the source files named in each table. Where something has not been checked against a datasheet or silicon, the table says so.

- **Tiny Tapeout tile** (`tt_um_hydra_mom`, `tt/tile/src/tt_um_hydra_mom.sv`): the scheduler only. Hardened (v3.11, 2026-10-21) with 0 disconnected pins.
- **SkyWater 130 OpenFrame chip** (`openframe_project_wrapper`, `sky130/rtl/hydra_openframe_top.sv`): 44 general-purpose pads plus the padframe's power, reset and control pins. Simulated through its pads (`make sky130`). Never hardened, so it has no package pin numbers yet.

Abbreviations: SPI (Serial Peripheral Interface), I2C (Inter-Integrated Circuit bus), GPIO (general-purpose input/output), GPI (general-purpose input), GPO (general-purpose output), POR (power-on reset).

## 1. Tiny Tapeout tile (4×4 tiles, 66 ns clock)

Every signal pin has a function since v3.11. The v3.10 harden reported 14 disconnected pins (`ui_in[7:3]`, `uio_in[7:0]`, `ena`). The v3.11 harden reports 0 (`design__disconnected_pin__count`, `docs/timing.json`).

### Power

| Pin | Domain | Function |
|---|---|---|
| `VPWR` | 1.8 V digital supply | powers every standard cell in the tile; supplied by the Tiny Tapeout power grid |
| `VGND` | digital ground | ground for every standard cell; supplied by the Tiny Tapeout power grid |

Both appear only on the hardened netlist (the gate-level testbench ties them to 1 and 0, `tt/tile/test/tb.v`).

### Clock, reset, enable

| Pin | Dir | Function |
|---|---|---|
| `clk` | in | system clock, 15.15 MHz (66 ns) at sign-off |
| `rst_n` | in | asynchronous reset, active low; released through a two-flop synchroniser (`hydra_rst_sync`) |
| `ena` | in | high while the tile is selected on the Tiny Tapeout chip; readable as `PINS[13]` (register 0x0E) |

### Inputs `ui_in`

| Pin | Name | Function |
|---|---|---|
| `ui_in[0]` | SCK | SPI clock, mode 0, at most clk/8 |
| `ui_in[1]` | COPI | SPI data in |
| `ui_in[2]` | CSn | SPI chip select, active low; idle high |
| `ui_in[3]` | GPI[0] | general-purpose input, read in `PINS[8]` (0x0E) |
| `ui_in[4]` | GPI[1] | general-purpose input, `PINS[9]` |
| `ui_in[5]` | GPI[2] | general-purpose input, `PINS[10]` |
| `ui_in[6]` | GPI[3] | general-purpose input, `PINS[11]` |
| `ui_in[7]` | GPI[4] | general-purpose input, `PINS[12]` |

### Outputs `uo_out`

| Pin | Name | Function |
|---|---|---|
| `uo_out[0]` | CIPO | SPI data out |
| `uo_out[1]` | IRQ | any sticky STATUS flag (dispatched, unsupported, stale, frame or GO error); CLEAR_STICKY clears it |
| `uo_out[2]` | engine[0] | engine of the last dispatch |
| `uo_out[3]` | engine[1] | |
| `uo_out[4]` | engine[2] | |
| `uo_out[5]` | dispatched | sticky until CLEAR_STICKY |
| `uo_out[6]` | any_busy | at least one tag outstanding |
| `uo_out[7]` | ready | the scheduler can accept a descriptor |

### Bidirectionals `uio` (all driven: `uio_oe = 8'hFF`)

| Pin | Name | Function |
|---|---|---|
| `uio[0]` | tag[0] | tag of the last dispatch (0 to 3) |
| `uio[1]` | tag[1] | |
| `uio[2]` | GPO[0] | general-purpose output, written in register 0x0F (v3.11; before, a tag bit that four tags never set) |
| `uio[3]` | GPO[1] | general-purpose output, 0x0F |
| `uio[4]` | margin[0] | 1 + floor(log2(runner-up margin)), 0 if none |
| `uio[5]` | margin[1] | |
| `uio[6]` | margin[2] | |
| `uio[7]` | margin[3] | |
| `uio_in[7:0]` | readback | the pad values, read in `PINS[7:0]`: a host compares them with what the tile drives to check the pad drivers and the board |

Checked by `make tile` (24 tests on RTL), `make tile-gl` (the same 24 tests on the hardened netlist), and the tile mutations (`test_reg_pins_read_every_spare_input`, `test_reg_gpo_drives_the_spare_bidirectionals`).

## 2. SkyWater 130 OpenFrame chip

The port list is ChipFoundry's `openframe_project_wrapper`, copied and diffed against upstream by `tools/check_openframe_ports.py`. The package pin numbers come from ChipFoundry's OpenFrame padframe and package. They are not assigned or checked in this repository, so the tables below name pads and wrapper ports, not package pins.

### Power and ground

The power domains below follow the Caravel and OpenFrame convention. Their voltages and which domain powers the user core are **not verified against ChipFoundry's OpenFrame datasheet in this repository**. They become fixed when the chip is hardened.

| Port | Domain | Function in HYDRA-130 |
|---|---|---|
| `vddio` | 3.3 V pad I/O supply | powers the 44 GPIO pad drivers and receivers |
| `vssio` | pad I/O ground | ground for the pad ring |
| `vdda` | 3.3 V analog supply | padframe analog supply; HYDRA-130 has no analog circuit on it |
| `vdda1` | 3.3 V user analog supply 1 | not used by HYDRA-130 logic (no analog blocks) |
| `vdda2` | 3.3 V user analog supply 2 | not used by HYDRA-130 logic |
| `vssa` | analog ground | padframe analog ground |
| `vssa1` | user analog ground 1 | not used by HYDRA-130 logic |
| `vssa2` | user analog ground 2 | not used by HYDRA-130 logic |
| `vccd` | 1.8 V digital supply | padframe digital supply (POR, pad control) |
| `vccd1` | 1.8 V user digital supply 1 | the expected supply of the HYDRA-130 core (set at harden) |
| `vccd2` | 1.8 V user digital supply 2 | second user digital domain; unassigned |
| `vssd` | digital ground | padframe digital ground |
| `vssd1` | user digital ground 1 | the expected ground of the HYDRA-130 core (set at harden) |
| `vssd2` | user digital ground 2 | ground of the second user digital domain |

The wrapper declares all 14 as `inout` and connects them to nothing in RTL. Power is wired by the padframe and the harden flow, not by logic.

### Padframe control inputs (not pads)

| Port | Function in HYDRA-130 |
|---|---|
| `porb_l` | power-on reset, 1.8 V domain, active low: held in reset while low (ANDed into the reset) |
| `resetb_l` | master reset, 1.8 V domain, active low: also ANDed into the reset |
| `porb_h`, `por_l`, `resetb_h` | the same resets in the 3.3 V domain or opposite polarity; not needed because the 1.8 V copies are used |
| `mask_rev[31:0]` | the mask revision the padframe supplies; readable over I2C at 0x08 to 0x0B (v3.11) |
| `gpio_loopback_one`, `gpio_loopback_zero` | constant 1 and 0 per pad, for tie-offs; not needed |

### The 44 pads

Each pad has `gpio_in` (and a 3.3 V copy `gpio_in_h`, not used), `gpio_out`, `gpio_oeb` (output enable, active low), `gpio_inp_dis` and the drive-mode controls `gpio_dm2/1/0` and others. HYDRA-130 enables the input buffer of all 44 pads. `analog_io` and `analog_noesd_io` give direct analog access to each pad and are not used: HYDRA-130 is digital only.

| Pad | Name | Dir | Function |
|---|---|---|---|
| 0 | clk | in | system clock |
| 1 | rst_n | in | reset, active low (ANDed with `porb_l` and `resetb_l`) |
| 2 | connect | in | strap: 1 connects the scheduler to pads 3 to 26 after reset, 0 keeps them inert; then locked |
| 3 | ui[0] SCK | in | scheduler SPI clock |
| 4 | ui[1] COPI | in | scheduler SPI data in |
| 5 | ui[2] CSn | in | scheduler SPI chip select, reads high while unconnected |
| 6 | ui[3] | in | scheduler input (pin personality: completion strobe) |
| 7 to 10 | ui[7:4] | in | scheduler inputs (pin personality: completion tag; register-mode strap 0xA at reset) |
| 11 | uo[0] CIPO | out | scheduler SPI data out |
| 12 | uo[1] IRQ | out | scheduler interrupt |
| 13 to 15 | uo[4:2] | out | engine of the last dispatch |
| 16 | uo[5] | out | dispatched |
| 17 | uo[6] | out | any_busy |
| 18 | uo[7] | out | ready |
| 19 to 26 | uio[7:0] | out | scheduler tag and margin |
| 27 | i2c_scl | in | I2C target clock (address 0x2A) |
| 28 | i2c_sda | open drain | I2C target data: pulled low or released, never driven high |
| 29 | gpio[0] | in/out | general-purpose I/O as below; in the microcontroller build, with I2C OWNER[0] (register 0x0D) set, the CPU's console UART transmitter (8N1, idle high, driven) |
| 30 to 43 | gpio[1] to gpio[14] | in/out | general-purpose I/O: inputs after reset, direction and value set over I2C (registers 0x01 to 0x06); in the microcontroller build, with OWNER[1] set, the values come from the CPU's LEDS register bits 0 to 13 (directions still from OE). The CPU reads all 15 pads in its BUTTONS register |

Pads 3 to 26 go through the pad multiplexer (`hydra_padmux`, formally proved) and stay inputs until the connect strap is sampled. Pads 27 to 43 belong to the I2C target (`common/rtl/hydra_i2c_gpio.sv`) and work from reset. A GPIO pad left unconnected on the board floats, so give it a pull resistor there.

Checked by `make sky130` (the chip through its pads: SPI to the scheduler, I2C to the GPIO, open-drain SDA, every input buffer on) and `make i2c-gpio` (the I2C target against an independent model). Mutations in `tools/mutate_mom.py` (I2C-01 to I2C-07, PAD-01, PAD-02).

### Not verified

- The drive-mode encodings (`dm = 110` driving, `001` receiving) follow the Caravel convention and have not been checked against ChipFoundry's `CF_gpio_config`.
- The power-domain voltages and assignments above are the convention, not a datasheet reading.
- No package pin numbers: the chip has not been hardened and no package has been chosen.
