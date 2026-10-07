# Bringing up the FPGA board

This is the first thing to do with the board, before any HYDRA image. The
self-test has almost no design in it, so if it misbehaves the fault is in the
setup — power, cable, driver, jumper, polarity — and not in the chip design.
Chasing a setup fault through a dispatcher image wastes an evening.

**Every command block assumes a brand new terminal.** Blocks that start with
`PS>` run in **Windows PowerShell**; everything else runs in **WSL (Ubuntu)**.

---

## 1. The board

**Lattice ECP5 Evaluation Board, part number `LFE5UM5G-85F-EVN`.**

It carries an ECP5-5G FPGA in a 381-ball package (`LFE5UM5G-85F-8BG381`),
84,000 lookup tables, eight user LEDs, eight DIP switches, push buttons, and
an FTDI FT2232H USB chip that provides both the programming (JTAG) link and a
serial port over one cable.

Why this board and not another: every HYDRA image in this repository already
targets it, the ECP5 family is fully supported by the open toolchain
(Yosys, nextpnr, Project Trellis, openFPGALoader) so nothing here needs a
vendor licence, and the on-board FTDI chip means no extra adapter for either
programming or the serial port.

### The documents

| document | number | what it is for |
|---|---|---|
| ECP5 Evaluation Board User Guide | **FPGA-EB-02017** | jumpers, power, switch and LED locations, schematics |
| ECP5 and ECP5-5G Family Data Sheet | **FPGA-DS-02012** | the FPGA itself: I/O standards, timing, configuration |

- Board page (both documents are linked there):
  <https://www.latticesemi.com/en/Products/DevelopmentBoardsAndKits/ECP5EvaluationBoard>
- User guide, direct: <https://www.mouser.com/pdfdocs/FPGA-EB-02017-1-0-ECP5-Evaluation-Board.pdf>

**Watch for EB98.** That number turns up in searches and is the user guide
for the *Versa* board — a different product with a different pin-out. Using
it for this board would give wrong pin numbers.

The pin numbers this repository uses do **not** come from memory or from a
guide transcribed by hand. They come from the LiteX-Boards platform file for
this board, fetched by `make bootstrap` and checked by `make boards`.

---

## 2. Before powering on

**Power.** Per the user guide, most of the board is supplied by on-board
regulators from an **external 12 V supply**. Check your kit includes one, and
check the guide for any jumper that selects the power source.

**The serial port jumpers.** The FPGA's serial pins (P2, P3) reach the FTDI
chip's second channel through jumpers. The repository's board notes point at
**J38/J39** — confirm the positions against the user guide before relying on
it. Without them fitted, programming still works but the serial test will
show nothing.

**Switches.** Set all eight DIP switches OFF to start.

---

## 3. Make the board visible to WSL

WSL does not see USB devices on its own. The Windows tool `usbipd-win`
forwards one across. Plug the board's USB cable in first.

Once, to install it:

```powershell
PS> winget install --exact dorssel.usbipd-win
```

Then, each time you plug the board in. Open PowerShell **as Administrator**:

```powershell
PS> usbipd list
```

Find the line mentioning `FT2232` or `USB Serial Converter` (vendor
`0403`, product `6010`). Note its `BUSID`, for example `2-3`. Then:

```powershell
PS> usbipd bind --busid 2-3
PS> usbipd attach --wsl --busid 2-3
```

`bind` is needed only the first time for that port. `attach` is needed every
time the board is plugged in or WSL restarts.

Back in WSL, confirm it arrived:

```bash
lsusb | grep -i 0403
ls /dev/ttyUSB*
```

You should see the FTDI device and two serial ports, `/dev/ttyUSB0` and
`/dev/ttyUSB1`. The FT2232H has two channels: the first is used for
programming, the second is the serial port.

---

## 4. Install the tools

```bash
sudo apt update
sudo apt install -y openfpgaloader yosys nextpnr-ecp5 fpga-trellis python3-serial
```

Let your user reach the device without `sudo`:

```bash
echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0666"' \
  | sudo tee /etc/udev/rules.d/99-ftdi-ecp5.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo usermod -aG dialout "$USER"
```

Log out of WSL and back in (`wsl --shutdown` from PowerShell, then reopen)
so the group change applies.

Check everything the build needs:

```bash
cd ~/src/hydra-skywater130
make doctor
```

---

## 5. Build and check the self-test

Simulate it first. If this fails, there is no point putting it on a board:

```bash
cd ~/src/hydra-skywater130
make selftest
```

Expect `PASS tb_fpga_selftest: 28 checks`. Then build the bitstream:

```bash
cd ~/src/hydra-skywater130
make selftest-bit
```

---

## 6. Flash it

**To the FPGA's memory** — fast, and gone when power is removed. Use this for
every test:

```bash
cd ~/src/hydra-skywater130
make flash-selftest
```

which runs:

```bash
openFPGALoader -b ecp5_evn fpga/build/ecp5-evn-selftest/hydra_ecp5_evn_selftest.bit
```

**To the SPI flash** — survives power-off, loads on every boot. Only once the
image is known good:

```bash
cd ~/src/hydra-skywater130
openFPGALoader -b ecp5_evn -f fpga/build/ecp5-evn-selftest/hydra_ecp5_evn_selftest.bit
```

If `openFPGALoader` says it cannot find a device, go back to step 3: the
board is not attached to WSL.

---

## 7. The test, step by step

Open the serial port in a second terminal **before** flashing, so you catch
the banner:

```bash
python3 -m serial.tools.miniterm /dev/ttyUSB1 115200
```

Then work down this table. Each row tests one thing.

| # | do this | you should see | if not |
|---|---|---|---|
| 1 | flash the image | one **lit** LED walks 0→7, twice | nothing: bitstream did not load or no clock. One **dark** LED walking: LED polarity inverted, see below |
| 2 | watch the terminal | `HYDRA-130 SELFTEST OK` | nothing: serial jumpers (step 2) or wrong `ttyUSB` |
| 3 | press the user button | the walk replays | nothing: the button is not the one on P4, see the user guide |
| 4 | switch 8 OFF, flip switches 1–7 one at a time | LED *n* follows switch *n*; LED 7 blinks once a second | an LED not following: note which. The terminal line tells you whether the FPGA saw the switch |
| 5 | each flip | a line like `SW 00100000` | the line shows what the FPGA sees: the first digit is switch 1 |
| 6 | switch 8 ON, then flip switch 3 | `011` blinks three times on LEDs 0–2 | the FPGA names the switch it saw change |
| 7 | type any character | the same character comes back | nothing: the receive path, pin P2 |

**Reading step 1 carefully.** The walk is designed so LED polarity is obvious
the moment it starts. One lit LED moving means everything is right. One dark
LED moving through a row of lit ones means the board drives its LEDs the
other way from what `fpga/boards/ecp5-evn.yaml` assumes — change
`led_active: high` to `led_active: low`, run `make selftest-bit`, and reflash.
That assumption has never been checked against real hardware; this is where
it gets checked.

**Reading steps 4 and 5 together.** If an LED does not light but the terminal
shows the switch changing, the switch and FPGA are fine and the fault is the
LED or its pin. If the terminal does not show the change either, the fault is
the switch or its pin. One test, two independent readings, and the fault is
located.

---

## 8. When the self-test passes

The setup is proven: power, cable, driver, programming, clock, LEDs,
switches, button and serial port all work. Only now is it worth loading a
HYDRA image:

```bash
cd ~/src/hydra-skywater130
openFPGALoader -b ecp5_evn fpga/build/ecp5-evn-mem/hydra_ecp5_evn_mem.bit
python3 tools/hydra_host.py --port /dev/ttyUSB1 selftest
```

If *that* fails, you know the fault is in the design, because everything
underneath it was just verified.

---

## 9. What to send back

Whatever happens, the useful report is: which row of the table failed, what
you saw instead, and the terminal output. "It doesn't work" is one
observation; "row 1 shows a dark LED walking" is a diagnosis.
