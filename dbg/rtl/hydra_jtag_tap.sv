/*
 * hydra_jtag_tap.sv -- IEEE 1149.1 test access port
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHY BOTH THIS AND THE SERIAL PORT
 * ===========================================================================
 * The serial path already loads and runs. This exists for the case the
 * serial path cannot help with: silicon that comes back and does nothing.
 * A test access port is reachable when the system clock is wrong, when the
 * bridge is misconfigured, and when firmware never started, because it has
 * its OWN clock -- TCK, supplied by the probe -- and does not depend on any
 * of that.
 *
 * Two independent ways in is the whole argument. They share nothing except
 * the register map they both target: separate clocks, separate state
 * machines, separate pins. A fault that takes out one leaves the other.
 *
 * ===========================================================================
 * WHAT IT COSTS
 * ===========================================================================
 * Four pins: TCK, TMS, TDI, TDO. The optional TRST is not implemented --
 * the standard requires that five TCKs with TMS high reach Test-Logic-Reset
 * from ANY state, which makes a reset pin a convenience rather than a
 * necessity, and a pin is worth more than the convenience here. That
 * property is proved, not assumed: see dbg/formal/jtag_tap.sby.
 *
 * ===========================================================================
 * CONFORMANCE, STATED HONESTLY
 * ===========================================================================
 * Implemented: the 16-state controller, a 4-bit instruction register that
 * captures 01 in its two low bits as the standard requires, BYPASS, IDCODE
 * selected at reset, and a user data register.
 *
 * NOT implemented: boundary scan. There are no boundary scan cells around
 * the pads, so SAMPLE, PRELOAD and EXTEST are absent. This is a debug access
 * port that speaks the JTAG protocol, not a boundary-scan-testable device,
 * and calling it "JTAG compliant" without that sentence would be a lie a
 * test engineer would catch in a minute.
 *
 * The identification code's manufacturer field is NOT a real JEDEC
 * identifier -- this project does not have one. It is a recognisable
 * placeholder so a probe can tell the chip apart, and it must be replaced
 * before anyone treats it as an identity.
 */
`default_nettype none

module hydra_jtag_tap #(
  parameter int unsigned IRW    = 4,
  parameter logic [31:0] IDCODE = 32'h1130_001D,   // low bit 1, per the standard
  parameter int unsigned DRW    = 40               // user register: rw + addr + data
) (
  // ---- the probe's domain -------------------------------------------------
  input  wire              tck,
  input  wire              tms,
  input  wire              tdi,
  output logic             tdo,
  output logic             tdo_oe,

  // ---- the user data register, in the probe's domain ----------------------
  // A capture takes a snapshot to shift out; an update hands the shifted
  // value over. Crossing into the system clock is somebody else's job and
  // is done with a handshake -- see hydra_jtag_bridge.sv.
  output logic [DRW-1:0]   user_dr,
  output logic             user_update,
  input  wire [DRW-1:0]    user_capture,

  // ---- observability ------------------------------------------------------
  output logic [IRW-1:0]   ir,
  output logic             in_reset
);
  // ---- the sixteen states -------------------------------------------------
  typedef enum logic [3:0] {
    TEST_LOGIC_RESET = 4'h0, RUN_TEST_IDLE = 4'h1,
    SELECT_DR        = 4'h2, CAPTURE_DR    = 4'h3, SHIFT_DR  = 4'h4,
    EXIT1_DR         = 4'h5, PAUSE_DR      = 4'h6, EXIT2_DR  = 4'h7,
    UPDATE_DR        = 4'h8,
    SELECT_IR        = 4'h9, CAPTURE_IR    = 4'hA, SHIFT_IR  = 4'hB,
    EXIT1_IR         = 4'hC, PAUSE_IR      = 4'hD, EXIT2_IR  = 4'hE,
    UPDATE_IR        = 4'hF
  } tap_state_e;

  tap_state_e st, nxt;

  always_comb begin
    unique case (st)
      TEST_LOGIC_RESET: nxt = tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
      RUN_TEST_IDLE:    nxt = tms ? SELECT_DR        : RUN_TEST_IDLE;
      SELECT_DR:        nxt = tms ? SELECT_IR        : CAPTURE_DR;
      CAPTURE_DR:       nxt = tms ? EXIT1_DR         : SHIFT_DR;
      SHIFT_DR:         nxt = tms ? EXIT1_DR         : SHIFT_DR;
      EXIT1_DR:         nxt = tms ? UPDATE_DR        : PAUSE_DR;
      PAUSE_DR:         nxt = tms ? EXIT2_DR         : PAUSE_DR;
      EXIT2_DR:         nxt = tms ? UPDATE_DR        : SHIFT_DR;
      UPDATE_DR:        nxt = tms ? SELECT_DR        : RUN_TEST_IDLE;
      SELECT_IR:        nxt = tms ? TEST_LOGIC_RESET : CAPTURE_IR;
      CAPTURE_IR:       nxt = tms ? EXIT1_IR         : SHIFT_IR;
      SHIFT_IR:         nxt = tms ? EXIT1_IR         : SHIFT_IR;
      EXIT1_IR:         nxt = tms ? UPDATE_IR        : PAUSE_IR;
      PAUSE_IR:         nxt = tms ? EXIT2_IR         : PAUSE_IR;
      EXIT2_IR:         nxt = tms ? UPDATE_IR        : SHIFT_IR;
      UPDATE_IR:        nxt = tms ? SELECT_DR        : RUN_TEST_IDLE;
      default:          nxt = TEST_LOGIC_RESET;
    endcase
  end

  // The controller has NO reset input: the standard's guarantee is that five
  // TCKs with TMS high reach Test-Logic-Reset from any state, so the state
  // register powers up wherever it likes and the probe walks it home. That
  // is what makes this reachable on a chip whose reset is broken.
  always_ff @(posedge tck) st <= nxt;

  // ---- instruction register -----------------------------------------------
  localparam logic [IRW-1:0] INST_IDCODE = IRW'('h1);
  localparam logic [IRW-1:0] INST_USER   = IRW'('h8);
  localparam logic [IRW-1:0] INST_BYPASS = {IRW{1'b1}};

  logic [IRW-1:0] ir_shift;

  always_ff @(posedge tck) begin
    if (st == TEST_LOGIC_RESET) begin
      ir <= INST_IDCODE;          // the standard's required reset instruction
    end else if (st == CAPTURE_IR) begin
      // The two low bits must capture 01. A probe uses this to work out the
      // instruction register's length by shifting and watching the pattern.
      ir_shift <= {{(IRW-2){1'b0}}, 2'b01};
    end else if (st == SHIFT_IR) begin
      ir_shift <= {tdi, ir_shift[IRW-1:1]};
    end else if (st == UPDATE_IR) begin
      ir <= ir_shift;
    end
  end

  // ---- data registers ------------------------------------------------------
  logic [31:0]    id_shift;
  logic           bypass_bit;
  logic [DRW-1:0] user_shift;

  wire sel_id   = (ir == INST_IDCODE);
  wire sel_user = (ir == INST_USER);

  always_ff @(posedge tck) begin
    user_update <= 1'b0;

    if (st == CAPTURE_DR) begin
      id_shift   <= IDCODE;
      user_shift <= user_capture;
      bypass_bit <= 1'b0;
    end else if (st == SHIFT_DR) begin
      id_shift   <= {tdi, id_shift[31:1]};
      user_shift <= {tdi, user_shift[DRW-1:1]};
      bypass_bit <= tdi;
    end else if (st == UPDATE_DR) begin
      if (sel_user) begin
        user_dr     <= user_shift;
        user_update <= 1'b1;
      end
    end
  end

  // ---- the output pin ------------------------------------------------------
  // Data changes on the FALLING edge of TCK so the probe, which samples on
  // the rising edge, sees it settled. Getting this backwards is the classic
  // way to build a port that works in simulation and not on a bench.
  wire shifting = (st == SHIFT_DR) || (st == SHIFT_IR);
  wire tdo_next = (st == SHIFT_IR) ? ir_shift[0]
                : sel_id           ? id_shift[0]
                : sel_user         ? user_shift[0]
                :                    bypass_bit;

  always_ff @(negedge tck) begin
    tdo    <= tdo_next;
    tdo_oe <= shifting;
  end

  assign in_reset = (st == TEST_LOGIC_RESET);

`ifdef FORMAL
  // THE property that makes the reset pin unnecessary: five TCKs with TMS
  // high reach Test-Logic-Reset from any state whatsoever. Proved from an
  // arbitrary starting state -- which is exactly the situation on a chip
  // that powered up wrong.
  // Initialised, so it counts only the TMS-high clocks actually observed
  // since the start of the trace. Left free, induction starts it at five
  // with the state machine anywhere and reports a failure for a sequence
  // that never happened.
  logic [2:0] tms_run = 3'd0;
  always_ff @(posedge tck) tms_run <= tms ? ((tms_run == 3'd7) ? 3'd7 : tms_run + 3'd1)
                                          : 3'd0;

  always_ff @(posedge tck)
    if (tms_run >= 3'd5) assert (st == TEST_LOGIC_RESET);

  // Test-Logic-Reset selects the identification code, so a probe that knows
  // nothing about this chip can still read what it is.
  logic past_valid = 1'b0;
  always_ff @(posedge tck) past_valid <= 1'b1;

  always_ff @(posedge tck)
    if (past_valid && $past(st) == TEST_LOGIC_RESET) assert (ir == INST_IDCODE);

  // The escape hatch is reachable, and reset really does select the
  // identification code -- so these proofs are not vacuous.
  always_ff @(posedge tck) cover (st == TEST_LOGIC_RESET);
  always_ff @(posedge tck) cover (st == SHIFT_DR && ir == INST_IDCODE);

  // The output only drives while shifting; at all other times the pin is
  // released so several devices can share a chain.
  // tdo_oe is set on the FALLING edge from the state that was current then,
  // so at a rising edge it reflects the state before the previous rising
  // edge -- two $past levels, not one. Writing it with one level failed and
  // the counterexample said so.
  always_ff @(posedge tck)
    if (past_valid && !(st inside {SHIFT_DR, SHIFT_IR})) assert (!tdo_oe);
`endif
endmodule

`default_nettype wire
