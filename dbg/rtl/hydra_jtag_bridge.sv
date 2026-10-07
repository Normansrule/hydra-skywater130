/*
 * hydra_jtag_bridge.sv -- the test port's access to the register map
 *
 * Copyright (c) 2026 Aleksander J. Norman
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===========================================================================
 * TWO CLOCKS THAT KNOW NOTHING ABOUT EACH OTHER
 * ===========================================================================
 * TCK comes from the probe. It is slow, it is not continuous -- it stops
 * whenever the operator stops clocking -- and it has no defined phase
 * relationship to the system clock. That last point is the whole problem: a
 * signal sampled while it is changing can settle either way, or settle
 * differently in two places, and a debug port that works on the bench and
 * hangs once in a thousand tries in the field is almost always this.
 *
 * The shape used here is the standard one and it is worth naming:
 *
 *   TOGGLE HANDSHAKE. The request is not a pulse -- a pulse one TCK long
 *   can be missed entirely by a faster or slower system clock, or seen
 *   twice. It is a level that TOGGLES, synchronised through two flops, and
 *   the far side acts on the EDGE it sees. A toggle cannot be missed: it
 *   stays until it is noticed.
 *
 *   PAYLOAD IS NOT SYNCHRONISED. Address and data cross as plain wires,
 *   with no synchroniser at all. That is correct and deliberate: they are
 *   held still by the requester from before the toggle until after the
 *   acknowledgement, so the system side only ever samples them long after
 *   they stopped moving. Putting synchronisers on a 39-bit payload would
 *   cost 78 flops and make it WORSE, because each bit would resolve
 *   independently and a word could cross half-old and half-new.
 *
 *   ONE OUTSTANDING REQUEST. While a transfer is in flight the bridge is
 *   busy and further updates are ignored rather than queued. The busy flag
 *   is visible in the word the probe captures, so software polls it. This
 *   is the honest simple thing; a queue here would be a second concurrency
 *   problem in the name of speed nobody needs from a debug port.
 *
 * ===========================================================================
 * WHAT IS NOT HANDLED
 * ===========================================================================
 * If the probe stops clocking mid-transfer the system side still completes
 * and parks; the result waits in a register until TCK returns. That is
 * fine. What is NOT handled is a system clock that is stopped or broken: no
 * acknowledgement ever comes back, the bridge stays busy, and the probe
 * sees that in the busy flag. Reading registers with the system clock dead
 * would need the register file itself to run on TCK, which is a much larger
 * change and is not pretended here.
 */
`default_nettype none

module hydra_jtag_bridge #(
  parameter int unsigned AW  = 7,
  parameter int unsigned DW  = 32
) (
  // ---- probe's domain ------------------------------------------------------
  input  wire                tck,
  input  wire                trst_n,        // from the controller's reset state
  input  wire [AW+DW:0]      user_dr,       // {rw, addr, wdata}
  input  wire                user_update,
  output logic [AW+DW:0]     user_capture,  // {busy, addr, rdata}

  // ---- system domain -------------------------------------------------------
  input  wire                clk,
  input  wire                rst_n,
  output logic               reg_we,
  output logic               reg_re,
  output logic [AW-1:0]      reg_addr,
  output logic [DW-1:0]      reg_wdata,
  input  wire [DW-1:0]       reg_rdata
);
  // ---- request side, in the probe's domain ---------------------------------
  logic            req_tog;        // toggles once per accepted request
  logic            busy;
  logic            rw_q;
  logic [AW-1:0]   addr_q;
  logic [DW-1:0]   wdata_q;
  logic [DW-1:0]   rdata_q;

  // acknowledgement, brought back across two flops
  logic            ack_tog;
  logic [1:0]      ack_sync;
  wire             ack_edge = ack_sync[1] ^ ack_tog;

  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      req_tog <= 1'b0; busy <= 1'b0; ack_tog <= 1'b0; ack_sync <= 2'b00;
      rw_q <= 1'b0; addr_q <= '0; wdata_q <= '0; rdata_q <= '0;
    end else begin
      ack_sync <= {ack_sync[0], ack_tog_sys};

      if (ack_edge) begin
        // The far side finished. Take the read data and release.
        ack_tog <= ack_sync[1];
        rdata_q <= rdata_sys;
        busy    <= 1'b0;
      end else if (user_update && !busy) begin
        // Payload is captured HERE and held still until the handshake
        // completes, which is what makes the unsynchronised crossing safe.
        rw_q    <= user_dr[AW+DW];
        addr_q  <= user_dr[AW+DW-1 -: AW];
        wdata_q <= user_dr[DW-1:0];
        req_tog <= ~req_tog;
        busy    <= 1'b1;
      end
    end
  end

  assign user_capture = {busy, addr_q, rdata_q};

  // ---- service side, in the system domain ----------------------------------
  logic [1:0] req_sync;
  logic       req_seen;
  logic       ack_tog_sys;
  logic [DW-1:0] rdata_sys;

  wire req_edge = req_sync[1] ^ req_seen;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_sync <= 2'b00; req_seen <= 1'b0; ack_tog_sys <= 1'b0;
      reg_we <= 1'b0; reg_re <= 1'b0; reg_addr <= '0; reg_wdata <= '0;
      rdata_sys <= '0;
    end else begin
      req_sync <= {req_sync[0], req_tog};
      reg_we   <= 1'b0;
      reg_re   <= 1'b0;

      if (req_edge) begin
        req_seen  <= req_sync[1];
        reg_addr  <= addr_q;          // stable: held since before the toggle
        reg_wdata <= wdata_q;
        reg_we    <= rw_q;
        reg_re    <= ~rw_q;
      end else if (reg_re_q) begin
        // One cycle after a read is issued the register file has answered.
        rdata_sys   <= reg_rdata;
        ack_tog_sys <= ~ack_tog_sys;
      end else if (reg_we_q) begin
        ack_tog_sys <= ~ack_tog_sys;
      end
    end
  end

  logic reg_we_q, reg_re_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin reg_we_q <= 1'b0; reg_re_q <= 1'b0; end
    else        begin reg_we_q <= reg_we; reg_re_q <= reg_re; end
  end

`ifdef FORMAL
  // One request in, one access out. The failure this guards against is a
  // toggle seen twice -- which is what happens when someone "simplifies"
  // the edge detector into a level.
  logic started = 1'b0;
  always_ff @(posedge clk) started <= 1'b1;

  always_ff @(posedge clk) if (started && rst_n && $past(rst_n)) begin
    // An access only ever follows an edge on the synchronised request.
    if (reg_we || reg_re) assert ($past(req_edge));
    // Never both at once.
    assert (!(reg_we && reg_re));
  end

  always_ff @(posedge tck) if (trst_n) begin
    // While busy, no new request is taken: the payload cannot move under
    // the far side's feet.
    if (busy && !ack_edge) assert ($stable(addr_q) && $stable(wdata_q));
  end
`endif
endmodule

`default_nettype wire
