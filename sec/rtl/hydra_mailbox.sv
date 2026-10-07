/*
 * hydra_mailbox.sv -- a narrow command interface, after Caliptra's mailbox
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * WHAT THIS TAKES FROM CALIPTRA, AND WHAT IT DOES NOT
 * ===========================================================================
 * The protocol is Caliptra's, as documented in chipsalliance/Caliptra
 * (doc/Caliptra.md) and the integration specification in caliptra-rtl:
 *
 *   1. The requester READS the LOCK register. A returned 0 means the lock
 *      was granted and is now held; a returned 1 means somebody else has it.
 *      Acquiring by READING is the part worth copying -- it makes the grant
 *      atomic in the hardware, with no compare-and-swap and no window where
 *      two requesters both believe they won.
 *   2. Requester writes COMMAND, then DLEN, then the payload to DATAIN.
 *   3. Requester writes EXECUTE.
 *   4. Requester polls STATUS until it is no longer CMD_BUSY. It can become
 *      DATA_READY, CMD_COMPLETE or CMD_FAILURE.
 *   5. Requester clears EXECUTE, which releases the lock.
 *
 * Caliptra also remembers WHO took the lock and treats writes from anyone
 * else as protocol violations. That is here too: the owner's identifier is
 * latched on grant, and a write from a different requester is refused and
 * raises a protocol error rather than being quietly applied. An interface
 * that accepts writes from whoever happens to write is not a boundary.
 *
 * NOT taken: Caliptra's mailbox is 128 kilobytes of error-correcting static
 * memory with a full command set, firmware behind it, and an entire
 * microcontroller. This is the protocol shape at a scale that fits a tile --
 * a small payload buffer and the state machine. Sharing a protocol is not
 * the same as being Caliptra, and this file should never be described as
 * containing Caliptra code. It contains none; it was written from the
 * public specification.
 *
 * The payload buffer is deliberately small. Sizing it to a real firmware
 * image would consume the tile; the interesting part here is the lock and
 * the ownership rules, which do not change with depth.
 */
`default_nettype none

module hydra_mailbox #(
  parameter int unsigned DW    = 32,
  parameter int unsigned DEPTH = 16,      // payload words
  parameter int unsigned UW    = 4        // requester identifier width
) (
  input  wire              clk,
  input  wire              rst_n,

  // ---- requester side ------------------------------------------------------
  input  wire              req_valid,
  input  wire [UW-1:0]     req_user,      // who is asking
  input  wire [2:0]        req_reg,       // which register
  input  wire              req_write,
  input  wire [DW-1:0]     req_wdata,
  output logic [DW-1:0]    req_rdata,
  output logic             req_error,     // protocol violation by this requester

  // ---- the side that services commands -------------------------------------
  output logic             cmd_valid,     // EXECUTE written: a command is ready
  output logic [DW-1:0]    cmd_code,
  output logic [DW-1:0]    cmd_dlen,
  input  wire              cmd_done,
  input  wire [1:0]        cmd_status_in,
  output logic [$clog2(DEPTH)-1:0] buf_addr,
  input  wire              buf_re,
  output logic [DW-1:0]    buf_rdata,

  output logic             locked,
  output logic [UW-1:0]    owner
);
  // Register map, following Caliptra's naming so the protocol reads the same
  localparam logic [2:0] R_LOCK    = 3'd0;
  localparam logic [2:0] R_CMD     = 3'd1;
  localparam logic [2:0] R_DLEN    = 3'd2;
  localparam logic [2:0] R_DATAIN  = 3'd3;
  localparam logic [2:0] R_DATAOUT = 3'd4;
  localparam logic [2:0] R_EXECUTE = 3'd5;
  localparam logic [2:0] R_STATUS  = 3'd6;

  localparam logic [1:0] CMD_BUSY     = 2'b00;
  localparam logic [1:0] DATA_READY   = 2'b01;
  localparam logic [1:0] CMD_COMPLETE = 2'b10;
  localparam logic [1:0] CMD_FAILURE  = 2'b11;

  localparam int AWB = $clog2(DEPTH);

  logic [DW-1:0] cmd_q, dlen_q;
  logic [1:0]    status_q;
  logic          execute_q;
  logic [AWB-1:0] wptr, rptr;
  logic [DW-1:0] payload [DEPTH];

  // A requester other than the owner may only READ the lock register -- that
  // is how it discovers the mailbox is busy. Anything else from a stranger
  // is a protocol violation.
  wire is_owner  = locked && (req_user == owner);
  wire stranger  = req_valid && locked && !is_owner && !(req_reg == R_LOCK && !req_write);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      locked <= 1'b0; owner <= '0; cmd_q <= '0; dlen_q <= '0;
      status_q <= CMD_BUSY; execute_q <= 1'b0;
      wptr <= '0; rptr <= '0; req_rdata <= '0; req_error <= 1'b0;
      cmd_valid <= 1'b0;
    end else begin
      req_error <= 1'b0;
      req_rdata <= '0;

      if (cmd_done && execute_q) status_q <= cmd_status_in;

      if (req_valid) begin
        if (stranger) begin
          // Refused, and reported. Caliptra raises an interrupt to its
          // microcontroller here; this raises a flag the register map can
          // expose. Either way it is not silently ignored, because a
          // violation is usually the first sign of something worse.
          req_error <= 1'b1;
          req_rdata <= '0;
        end else if (!req_write && req_reg == R_LOCK) begin
          // THE ATOMIC GRANT. Reading returns the PREVIOUS state and takes
          // the lock in the same cycle if it was free. No test-then-set, so
          // no window for two requesters to both win.
          req_rdata <= {{(DW-1){1'b0}}, locked};
          if (!locked) begin
            locked   <= 1'b1;
            owner    <= req_user;
            wptr     <= '0;
            rptr     <= '0;
            status_q <= CMD_BUSY;
          end
        end else if (is_owner) begin
          unique case (req_reg)
            R_CMD:     if (req_write) cmd_q  <= req_wdata; else req_rdata <= cmd_q;
            R_DLEN:    if (req_write) dlen_q <= req_wdata; else req_rdata <= dlen_q;
            R_DATAIN:  if (req_write) begin
                         payload[wptr] <= req_wdata;
                         if (wptr != AWB'(DEPTH-1)) wptr <= wptr + 1'b1;
                       end
            R_DATAOUT: if (!req_write) begin
                         req_rdata <= payload[rptr];
                         if (rptr != AWB'(DEPTH-1)) rptr <= rptr + 1'b1;
                       end
            R_STATUS:  req_rdata <= {{(DW-2){1'b0}}, status_q};
            R_EXECUTE: begin
              if (req_write) begin
                execute_q <= req_wdata[0];
                cmd_valid <= req_wdata[0];
                if (!req_wdata[0]) begin
                  // Clearing EXECUTE releases the lock, exactly as the
                  // specification says. This is the ONLY release path:
                  // no timeout, no forced takeover.
                  locked <= 1'b0;
                  owner  <= '0;
                end
              end else begin
                req_rdata <= {{(DW-1){1'b0}}, execute_q};
              end
            end
            default: req_rdata <= '0;
          endcase
        end else begin
          // Not locked and not a lock read: nothing to do, but say so.
          req_error <= req_write;
        end
      end

      if (cmd_valid && cmd_done) cmd_valid <= 1'b0;
    end
  end

  assign cmd_code = cmd_q;
  assign cmd_dlen = dlen_q;
  assign buf_addr = rptr;
  assign buf_rdata = payload[buf_re ? buf_addr : '0];

`ifdef FORMAL
  logic started = 1'b0;
  always_ff @(posedge clk) started <= 1'b1;
  always_ff @(posedge clk) if (!started) assume (!rst_n);

  always_ff @(posedge clk) if (started && rst_n && $past(rst_n)) begin
    // MUTUAL EXCLUSION. While the lock is held, the owner cannot change
    // without passing through the released state. This is the property the
    // whole design exists for: two requesters must never both believe they
    // hold it.
    if ($past(locked) && locked) assert (owner == $past(owner));

    // The lock is released only by the owner clearing EXECUTE.
    if ($past(locked) && !locked)
      assert ($past(req_valid) && $past(req_write) &&
              $past(req_reg) == R_EXECUTE && !$past(req_wdata[0]) &&
              $past(req_user) == $past(owner));

    // A stranger never becomes the owner.
    if ($past(stranger)) assert (locked && owner == $past(owner));

    // A stranger's write never lands: command and length are unchanged.
    if ($past(stranger) && $past(req_write))
      assert ($stable(cmd_q) && $stable(dlen_q));
  end

  always_ff @(posedge clk) begin
    cover (locked);
    cover (started && !locked && $past(locked));
    cover (req_error);
  end
`endif
endmodule

`default_nettype wire
