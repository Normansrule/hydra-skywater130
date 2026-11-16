/*
 * hydra_openframe_top.sv
 *
 * HYDRA-130 sky130 target: the OpenFrame padframe wrapper
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT THIS IS, AND WHAT IT IS NOT
 * ===========================================================================
 * This is the full-chip target: a ChipFoundry OpenFrame user project, 44 pads,
 * about 15 mm2 of user area, hardened as macros and assembled here.
 *
 * Today it contains ONE macro -- the TinyTapeout tile (the MOM dispatcher) --
 * and, on the pads the tile does not use, an I2C target with 15 GPIO.
 * That is deliberate. It makes the chip target real and testable now: the pad
 * plan, the pad multiplexer, the bring-up sequence and the chip-level
 * testbench all exist and run, and each SoC block drops in beside the tile as
 * its sources arrive. A wrapper with nothing in it proves nothing.
 *
 * The port list is copied from ChipFoundry's openframe_project_wrapper -- and
 * "copied" is the risk, so tools/check_openframe_ports.py diffs it against the
 * upstream file and fails if they have diverged.
 *
 * ===========================================================================
 * PAD PLAN (44 pads)
 * ===========================================================================
 *    0      clk            input, free-running
 *    1      rst_n          input, asynchronous, active low
 *    2      connect        strap: 1 connects the tile to the pads, 0 keeps
 *                          every pad inert. Sampled after reset, then locked.
 *                          The tile is held in reset until this has happened,
 *                          so it samples its own straps from real pins.
 *    3-10   ui_in[7:0]     tile inputs   (SPI: 3 = SCK, 4 = COPI, 5 = CSn)
 *   11-18   uo_out[7:0]    tile outputs  (SPI: 11 = CIPO)
 *   19-26   uio[7:0]       tile bidirectionals
 *   27      i2c_scl        I2C target clock, input (hydra_i2c_gpio, address 0x2A)
 *   28      i2c_sda        I2C target data, open drain: pulled low or released
 *   29-43   gpio[14:0]     general-purpose I/O, controlled over I2C; inputs
 *                          after reset (OE = 0), read back over I2C
 * Every pad has a function (v3.11). Before, 27-43 had their buffers off.
 *
 * ===========================================================================
 * WHY THE PAD MULTIPLEXER IS HERE FOR A DESIGN THAT FITS
 * ===========================================================================
 * The SoC needs 45 signals and OpenFrame has 44 pads, so pads must carry more
 * than one function eventually. Rather than bolt that on later, every
 * functional pad already goes through hydra_padmux (proved, 8/8 mutations
 * killed) with two alternatives: 0 is inert, 1 is the tile. Three consequences
 * that matter on silicon:
 *   - reset leaves every pad an input, so nothing is driven while the chip
 *     powers up and the bring-up board is being probed;
 *   - a chip that comes back with a wiring mistake can be held in the inert
 *     personality and probed, instead of fighting the board;
 *   - the selection locks, so firmware cannot re-route pins after boot.
 *
 * ===========================================================================
 * NOT VERIFIED HERE
 * ===========================================================================
 * The gpio_dm / vtrip / slow / analog control encodings below follow the
 * Caravel and OpenFrame convention (dm = 3'b110 for a digital output driver,
 * input buffer enabled by gpio_inp_dis = 0). They have NOT been checked
 * against silicon or against ChipFoundry's CF_gpio_config in this session.
 * Check them against the OpenFrame user guide before submitting: a wrong
 * drive-mode code turns a working design into a chip that cannot talk.
 * ===========================================================================
 */
`default_nettype none

`ifndef OPENFRAME_IO_PADS
`define OPENFRAME_IO_PADS 44
`endif

module openframe_project_wrapper #(
  // 0: the scheduler tile on pads 3-26 (what has been simulated since v1).
  // 1: the microcontroller (v3.12): the system tile -- scheduler, the Sixfold
  //    CPU on SkyWater 130 SRAM macros with secure boot, the TPU and the vector
  //    unit -- on the same pads, loaded and read over the I2C host bus.
  parameter int unsigned MCU = 0,
  parameter int unsigned MCU_SRAM_MODEL = 0,          // 1: the macro's model (Verilator, FPGA)
  parameter logic [255:0] MCU_BOOT_GOLDEN = 256'd0    // the one image the CPU will run
) (
  inout  vdda,  inout vdda1, inout vdda2,
  inout  vssa,  inout vssa1, inout vssa2,
  inout  vccd,  inout vccd1, inout vccd2,
  inout  vssd,  inout vssd1, inout vssd2,
  inout  vddio, inout vssio,

  input        porb_h,
  input        porb_l,
  input        por_l,
  input        resetb_h,
  input        resetb_l,
  input [31:0] mask_rev,

  input  [`OPENFRAME_IO_PADS-1:0] gpio_in,
  input  [`OPENFRAME_IO_PADS-1:0] gpio_in_h,
  output [`OPENFRAME_IO_PADS-1:0] gpio_out,
  output [`OPENFRAME_IO_PADS-1:0] gpio_oeb,
  output [`OPENFRAME_IO_PADS-1:0] gpio_inp_dis,
  output [`OPENFRAME_IO_PADS-1:0] gpio_ib_mode_sel,
  output [`OPENFRAME_IO_PADS-1:0] gpio_vtrip_sel,
  output [`OPENFRAME_IO_PADS-1:0] gpio_slow_sel,
  output [`OPENFRAME_IO_PADS-1:0] gpio_holdover,
  output [`OPENFRAME_IO_PADS-1:0] gpio_analog_en,
  output [`OPENFRAME_IO_PADS-1:0] gpio_analog_sel,
  output [`OPENFRAME_IO_PADS-1:0] gpio_analog_pol,
  output [`OPENFRAME_IO_PADS-1:0] gpio_dm2,
  output [`OPENFRAME_IO_PADS-1:0] gpio_dm1,
  output [`OPENFRAME_IO_PADS-1:0] gpio_dm0,

  inout  [`OPENFRAME_IO_PADS-1:0] analog_io,
  inout  [`OPENFRAME_IO_PADS-1:0] analog_noesd_io,

  input  [`OPENFRAME_IO_PADS-1:0] gpio_loopback_one,
  input  [`OPENFRAME_IO_PADS-1:0] gpio_loopback_zero
);

  localparam int NPADS    = `OPENFRAME_IO_PADS;
  localparam int P_CLK    = 0;
  localparam int P_RSTN   = 1;
  localparam int P_CONN   = 2;
  localparam int P_FIRST  = 3;          // first multiplexed pad
  localparam int NMUX     = 24;         // ui 8 + uo 8 + uio 8
  localparam int NALT     = 2;
  localparam int P_SCL    = P_FIRST + NMUX;     // 27
  localparam int P_SDA    = P_SCL + 1;          // 28
  localparam int P_GPIO   = P_SDA + 1;          // 29
  localparam int NGPIO    = NPADS - P_GPIO;     // 15

  wire _unused = &{porb_h, por_l, resetb_h, gpio_in_h,
                   gpio_loopback_one, gpio_loopback_zero, 1'b0};

  // ---------------------------------------------------------------------------
  // Clock and reset. porb_l and resetb_l are both power-on/master resets in
  // the 1.8 V domain; either one holds the design in reset, as does the pad.
  // ---------------------------------------------------------------------------
  wire clk    = gpio_in[P_CLK];
  wire arst_n = gpio_in[P_RSTN] & porb_l & resetb_l;

  wire rst_n;
  hydra_rst_sync u_rst (
    .clk(clk), .arst_n(arst_n), .scan_mode(1'b0), .scan_rst_n(1'b1), .rst_n(rst_n));

  // ---------------------------------------------------------------------------
  // The tile
  // ---------------------------------------------------------------------------
  wire [7:0] ui_in, uo_out, uio_in, uio_out, uio_oe;
  wire       padmux_locked;
  logic [1:0] tile_rel;

  // BRING-UP ORDER, and why it is not the obvious one.
  // The tile samples its personality strap (ui_in[7:4]) while ITS reset is
  // low. Until the pad multiplexer is connected, ui_in reads the inert idle
  // values, not the pins -- so releasing both resets together boots the tile
  // in the wrong personality with the pins right there. The tile is therefore
  // held in reset until the pads are connected and locked, and only then let
  // go. Caught by tb_openframe, which read an ID of zero.
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) tile_rel <= 2'd0;
    else if (padmux_locked && tile_rel != 2'd3) tile_rel <= tile_rel + 2'd1;

  wire tile_rst_n = rst_n & (tile_rel == 2'd3);

  // the I2C host bus (MCU only) drives the system tile's memory port
  wire             i2c_bus_we;
  wire [1:0]       i2c_bus_bank;
  wire [15:0]      i2c_bus_addr;
  wire [31:0]      i2c_bus_wdata;
  wire [31:0]      bus_rdata;
  // the CPU's console UART and LEDS (MCU only, v67), routed to GPIO pads by OWNER
  wire             cpu_uart_tx;
  wire [15:0]      cpu_gpio_out;
  wire [15:0]      cpu_gpio_in;

  generate
    if (MCU == 0) begin : g_tile
      hydra_mom_pins u_tile (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
        .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(tile_rst_n));
      assign bus_rdata = 32'd0;
      wire _unused_bus = &{1'b0, i2c_bus_we, i2c_bus_bank, i2c_bus_addr, i2c_bus_wdata};
      wire _unused_mcu = &{1'b0, MCU_SRAM_MODEL[0], MCU_BOOT_GOLDEN[0], cpu_gpio_in};   // MCU build only
      assign cpu_uart_tx = 1'b1; assign cpu_gpio_out = 16'd0;
    end else begin : g_mcu
      wire [31:0] dbg_ck, dbg_sck;
      wire [15:0] dbg_t, dbg_sj;
      wire        mem_refused;
      hydra_sys_tile #(
        .NENG(5), .TPU_ENGINE(1), .SIMD_ENGINE(1), .ABI_V2(1), .CPU_ENGINE(1),
        .SECURE_BOOT(1), .BOOT_GOLDEN(MCU_BOOT_GOLDEN),
        .CPU_CACHED(1), .CPU_SRAM(1), .CPU_SRAM_MODEL(MCU_SRAM_MODEL), .CPU_MEM_BYTES(16384), .CPU_CACHE_SETS(16)
      ) u_sys (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(tile_rst_n),
        .dbg_checksum(dbg_ck), .dbg_tiles(dbg_t), .dbg_simd_checksum(dbg_sck), .dbg_simd_jobs(dbg_sj),
        .mem_we(i2c_bus_we), .mem_bank(i2c_bus_bank), .mem_addr(i2c_bus_addr),
        .mem_wdata(i2c_bus_wdata), .mem_raddr(i2c_bus_addr), .mem_rdata(bus_rdata),
        .mem_refused(mem_refused),
        .cpu_uart_tx(cpu_uart_tx), .cpu_gpio_out(cpu_gpio_out), .cpu_gpio_in(cpu_gpio_in));
      wire _unused_dbg = &{1'b0, dbg_ck, dbg_t, dbg_sck, dbg_sj, mem_refused};
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Pad multiplexer: alternative 0 inert, alternative 1 the tile.
  // ---------------------------------------------------------------------------
  wire [NMUX*NALT-1:0] alt_out, alt_oe, alt_idle, alt_in;
  wire [NMUX-1:0]      pad_out, pad_oe, pad_in;

  genvar i;
  generate
    for (i = 0; i < NMUX; i++) begin : g_alt
      // alternative 0: inert. Never drives; a function reading it sees idle.
      assign alt_out [i*NALT + 0] = 1'b0;
      assign alt_oe  [i*NALT + 0] = 1'b0;
      assign alt_idle[i*NALT + 0] = 1'b0;

      if (i < 8) begin : g_ui            // inputs
        assign alt_out [i*NALT + 1] = 1'b0;
        assign alt_oe  [i*NALT + 1] = 1'b0;
        // An unconnected SPI chip-select must read high, not float low, or the
        // tile sees a frame the moment the personality is applied.
        assign alt_idle[i*NALT + 1] = (i == 5) ? 1'b1 : 1'b0;
        assign ui_in[i]             = alt_in[i*NALT + 1];
      end else if (i < 16) begin : g_uo  // outputs
        assign alt_out [i*NALT + 1] = uo_out[i - 8];
        assign alt_oe  [i*NALT + 1] = 1'b1;
        assign alt_idle[i*NALT + 1] = 1'b0;
      end else begin : g_uio             // bidirectionals
        assign alt_out [i*NALT + 1] = uio_out[i - 16];
        assign alt_oe  [i*NALT + 1] = uio_oe [i - 16];
        assign alt_idle[i*NALT + 1] = 1'b0;
        assign uio_in[i - 16]       = alt_in[i*NALT + 1];
      end
    end
  endgenerate

  // Bring-up: a few clocks after reset, connect the tile if the strap says so,
  // then lock. Held inert otherwise, which is the state a bad board wants.
  logic [3:0] boot_cnt;
  logic       cfg_we, cfg_lock;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      boot_cnt <= 4'd0; cfg_we <= 1'b0; cfg_lock <= 1'b0;
    end else begin
      cfg_we   <= 1'b0;
      cfg_lock <= 1'b0;
      if (boot_cnt != 4'd8) begin
        boot_cnt <= boot_cnt + 4'd1;
      end else if (!cfg_lock) begin
        boot_cnt <= 4'd9;
        cfg_we   <= gpio_in[P_CONN];
        cfg_lock <= gpio_in[P_CONN];
      end
    end
  end

  // The pad selection is read back nowhere on this chip (locked_q is), so it
  // is connected to a named wire and consumed rather than left empty.
  wire [NMUX-1:0] padmux_sel;
  wire _unused_sel = &{1'b0, padmux_sel};

  hydra_padmux #(.NPAD(NMUX), .NALT(NALT), .SELW(1), .RESET_SEL({NMUX{1'b0}})) u_padmux (
    .clk(clk), .rst_n(rst_n),
    .cfg_we(cfg_we), .cfg_sel({NMUX{1'b1}}), .cfg_lock(cfg_lock),
    .sel_q(padmux_sel), .locked_q(padmux_locked),
    .alt_out(alt_out), .alt_oe(alt_oe), .alt_idle(alt_idle), .alt_in(alt_in),
    .pad_out(pad_out), .pad_oe(pad_oe), .pad_in(pad_in));

  assign pad_in = gpio_in[P_FIRST +: NMUX];

  // ---------------------------------------------------------------------------
  // I2C target and general-purpose I/O on the remaining pads. Independent of
  // the tile and of the connect strap: it runs from the chip reset, and its
  // GPIO pads are inputs until a controller writes OE.
  // ---------------------------------------------------------------------------
  wire             sda_oe;
  wire [NGPIO-1:0] gpio_o, gpio_e, gpio_drv;
  wire [1:0]       gpio_owner;

  hydra_i2c_gpio #(.ADDR(7'h2A), .NGPIO(NGPIO), .HOST_BUS(MCU != 0)) u_i2c_gpio (
    .clk(clk), .rst_n(rst_n),
    .scl_i(gpio_in[P_SCL]), .sda_i(gpio_in[P_SDA]), .sda_oe(sda_oe),
    .gpio_in(gpio_in[P_GPIO +: NGPIO]), .mask_rev(mask_rev), .gpio_out(gpio_o), .gpio_oe(gpio_e), .owner(gpio_owner),
    .bus_we(i2c_bus_we), .bus_bank(i2c_bus_bank), .bus_addr(i2c_bus_addr), .bus_wdata(i2c_bus_wdata),
    .bus_rdata(bus_rdata));

  // ---------------------------------------------------------------------------
  // Pad control. oeb is active low. SDA is open drain: it only ever drives 0.
  // ---------------------------------------------------------------------------
  // GPIO owner (I2C register 0x0D, v67): OWNER[0] gives GPIO 0 to the CPU's
  // UART transmitter (driven, idle high); OWNER[1] gives GPIO 1 and up to its
  // LEDS register, with each pad's direction still set by OE. The CPU reads
  // every GPIO pad in BUTTONS, whoever drives it. In the MCU = 0 build the
  // CPU is absent: its UART idles high and its LEDS read 0.
  wire [NGPIO-1:0] gpio_e_w;
  assign gpio_drv  = {gpio_owner[1] ? cpu_gpio_out[NGPIO-2:0] : gpio_o[NGPIO-1:1],
                      gpio_owner[0] ? cpu_uart_tx : gpio_o[0]};
  assign gpio_e_w  = {gpio_e[NGPIO-1:1], gpio_owner[0] | gpio_e[0]};
  assign cpu_gpio_in = {{(16-NGPIO){1'b0}}, gpio_in[P_GPIO +: NGPIO]};
  wire _unused_cpu_led = &{1'b0, cpu_gpio_out[15:NGPIO-1]};
  wire [NPADS-1:0] out_w, oeb_w, inp_dis_w;
  assign out_w     = {gpio_drv, 1'b0, 1'b0, pad_out, {P_FIRST{1'b0}}};
  assign oeb_w     = {~gpio_e_w, ~sda_oe, 1'b1, ~pad_oe, {P_FIRST{1'b1}}};
  // Every pad is used, so every input buffer is on. A GPIO pad left
  // unconnected on the board floats: give it a pull resistor there.
  assign inp_dis_w = {NPADS{1'b0}};

  assign gpio_out     = out_w;
  assign gpio_oeb     = oeb_w;
  assign gpio_inp_dis = inp_dis_w;

  // Digital, no analog, standard trip point, fast slew, no holdover.
  assign gpio_dm2         = ~oeb_w;      // dm = 110 driving, 001 receiving
  assign gpio_dm1         = ~oeb_w;
  assign gpio_dm0         =  oeb_w;
  assign gpio_ib_mode_sel = {NPADS{1'b0}};
  assign gpio_vtrip_sel   = {NPADS{1'b0}};
  assign gpio_slow_sel    = {NPADS{1'b0}};
  assign gpio_holdover    = {NPADS{1'b0}};
  assign gpio_analog_en   = {NPADS{1'b0}};
  assign gpio_analog_sel  = {NPADS{1'b0}};
  assign gpio_analog_pol  = {NPADS{1'b0}};

endmodule

`default_nettype wire
