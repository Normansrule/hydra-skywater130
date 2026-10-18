// =============================================================================
// tb_sys_tile.sv -- the dispatcher, crossbar and engines, driven over SPI
// =============================================================================
// The same register map the PC script uses, against hardware engines. What it
// must show, and what the FPGA board should then show on the bench:
//   1. work reaches an engine and comes back with the right tag, with no host
//      writing completions;
//   2. CTRL.HOLD stalls dispatch, because it holds the engines not-ready;
//   3. with the TPU profile slow (ui_in[7:6]=01) the calibration loop moves
//      the 8x8x8 multiply off the TPU on its own;
//   4. with all engines fast again the decision does NOT come back -- see the
//      note at that step. This test documents the limitation rather than
//      hiding it, and will need inverting on the day exploration is added.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_sys_tile;
  localparam int HALF = 5;
  localparam logic [127:0] LARGE = 128'h30a00100010001000018000000000000;
  localparam logic [127:0] SMALL = 128'h30a00080008000800006000000000000;

  logic clk = 0, rst_n = 0;
  logic [7:0] ui = 8'b0000_0100;      // CSn high
  wire  [7:0] uo, uio, uio_oe;
  integer errors = 0;
  always #27.5 clk = ~clk;
  // A broken design must FAIL here, not hang (ci_selftest, 2026-10-11): about
  // twenty times the cycles a passing run needs.
  initial begin repeat (6000000) @(posedge clk); $display("FAIL tb_sys_tile: watchdog"); $fatal(1); end

  hydra_sys_tile #(.LAT_FAST(30), .LAT_SLOW(1500)) dut (
    .ui_in(ui), .uo_out(uo), .uio_in(8'h00), .uio_out(uio), .uio_oe(uio_oe),
    .ena(1'b1), .clk(clk), .rst_n(rst_n));

  // ---- SPI (mode 0) ---------------------------------------------------------
  logic [7:0] rbuf [24];
  logic [7:0] d [24];
  // Icarus cannot take unpacked arrays as task ports, so the frame buffer
  // `d` is module scope and xfer takes only the length.
  task automatic xfer(input int n);
    ui[2] = 1'b0;
    repeat (2*HALF) @(posedge clk);
    for (int i = 0; i < n; i++) begin
      logic [7:0] rx;
      for (int b = 7; b >= 0; b--) begin
        ui[1] = d[i][b];
        repeat (HALF) @(posedge clk);
        rx = {rx[6:0], uo[0]};
        ui[0] = 1'b1;
        repeat (HALF) @(posedge clk);
        ui[0] = 1'b0;
      end
      rbuf[i] = rx;
    end
    repeat (HALF) @(posedge clk);
    ui[2] = 1'b1;
    repeat (2*HALF) @(posedge clk);
  endtask

  task automatic wr(input logic [6:0] a, input int n, input logic [127:0] v);
    d[0] = {1'b0, a};
    for (int i = 0; i < n; i++) d[i+1] = v[(n-1-i)*8 +: 8];
    xfer(n+1);
  endtask
  task automatic rd(input logic [6:0] a, input int n, output logic [127:0] v);
    d[0] = {1'b1, a};
    for (int i = 1; i <= n; i++) d[i] = 8'h00;
    xfer(n+1);
    v = '0;
    for (int i = 0; i < n; i++) v = (v << 8) | rbuf[i+1];
  endtask

  logic [127:0] v;
  task automatic go(); wr(7'h03, 1, 128'h01); repeat (20) @(posedge clk); endtask
  task automatic result(output logic [2:0] eng, output logic [31:0] margin);
    rd(7'h06, 6, v); eng = v[47:45]; margin = v[39:8];
  endtask
  function automatic logic [15:0] status_of(input logic [127:0] x); return x[15:0]; endfunction

  logic [2:0] eng, first_eng;
  logic [31:0] margin;
  integer i, moved_at;

  // ---- RTL-02 (SkyWater 130 audit, 2026-10-11) ------------------------------
  // The register block records a dispatch (STATUS.DISPATCHED, RESULT engine
  // and tag, the IRQ) at the event it observes. In this system the crossbar
  // owns the handshake: a dispatch has happened only when the crossbar takes
  // it. Count both on every cycle; they must be the same events.
  integer obs_events = 0, xbar_events = 0, obs_early = 0;

  // ---- RTL-04: a multi-byte read is one snapshot -----------------------------
  // While `sampling` is set, record every distinct value the RESULT register
  // holds. A read is coherent if what came back is one of them; a torn read
  // (byte 0 from one dispatch, the rest from the next) is none of them.
  logic        sampling = 0;
  logic [47:0] seen_vals [16];
  integer      n_seen = 0;
  wire  [47:0] result_now = {dut.u_regs.r_engine, dut.u_regs.r_tag, 1'b0,
                             dut.u_regs.r_margin, dut.u_regs.r_errtag};
  always @(posedge clk) if (sampling) begin
    logic hit; hit = 0;
    for (int j = 0; j < n_seen; j++) if (seen_vals[j] === result_now) hit = 1;
    if (!hit && n_seen < 16) begin seen_vals[n_seen] = result_now; n_seen = n_seen + 1; end
  end
  always @(posedge clk) if (rst_n) begin
    if (dut.u_regs.dispatched) obs_events++;
    if (dut.disp_valid && dut.disp_accept) xbar_events++;
    if (dut.u_regs.dispatched && !(dut.disp_valid && dut.disp_accept)) begin
      obs_early++;
      if (obs_early < 3)
        $display("FAIL: at %0t the register block recorded a dispatch the crossbar had not taken", $time);
    end
  end

  initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (20) @(posedge clk);

    // ---- identity, so a wiring mistake fails here and not later ----------
    rd(7'h00, 4, v);
    if (v[31:0] !== 32'h48594D32) begin errors++; $display("FAIL: ID %h", v[31:0]); end

    // ---- 1. a dispatch reaches an engine and completes itself ------------
    wr(7'h01, 16, SMALL);
    go();
    repeat (200) @(posedge clk);
    rd(7'h05, 2, v);
    if (!v[11]) begin errors++; $display("FAIL: nothing dispatched, status %h", v[15:0]); end
    rd(7'h09, 2, v);
    if (v[15:0] !== 16'h0000) begin
      errors++; $display("FAIL: tag not retired by hardware, busy %h", v[15:0]);
    end
    $display("hardware completion: tags all retired with no host COMP write");

    // ---- 2. HOLD stalls dispatch ------------------------------------------
    wr(7'h02, 1, 128'h01);             // CTRL.HOLD
    wr(7'h01, 16, LARGE);
    go();
    repeat (100) @(posedge clk);
    rd(7'h05, 2, v);
    if (v[11]) begin errors++; $display("FAIL: dispatched while HOLD set"); end
    wr(7'h02, 1, 128'h00);
    repeat (400) @(posedge clk);
    rd(7'h05, 2, v);
    if (!v[11]) begin errors++; $display("FAIL: held work never dispatched"); end
    $display("HOLD: dispatch stalled, then released");

    // ---- 3. calibration moves the decision, engines only ------------------
    ui[7:6] = 2'b01;                   // TPU slow
    first_eng = 3'd7; moved_at = -1;
    for (i = 0; i < 80; i++) begin
      wr(7'h01, 16, LARGE);
      go();
      result(eng, margin);
      if (first_eng == 3'd7) first_eng = eng;
      if (eng != first_eng) begin moved_at = i; break; end
      // wait for the engine to finish on its own
      for (int w = 0; w < 4000; w++) begin
        rd(7'h09, 2, v);
        if (v[15:0] == 0) break;
      end
    end
    $display("slow-TPU profile: started on engine %0d, moved to %0d after %0d dispatches",
             first_eng, eng, moved_at);
    if (first_eng !== 3'd2) begin errors++; $display("FAIL: did not start on the TPU"); end
    if (moved_at < 0) begin errors++; $display("FAIL: decision never moved"); end

    // ---- 4. all fast again: the decision does NOT come back ---------------
    // FINDING (session 179d). mom_calibrate only updates k on a completion
    // for that engine and opclass, and nothing decays it. Once the dispatcher
    // stops choosing an engine, that engine is never measured again, so a
    // penalty learned from a transient slowdown is permanent until reset or a
    // CSR write. The loop is one-way.
    //
    // On silicon this means one hot spell, one bus contention burst or one
    // slow DMA steers work off an engine for the rest of the power cycle.
    // Cheapest fixes, in docs/BUILDOUT.md: decay k one step towards nominal
    // every N completions, or force a dispatch to the runner-up every M
    // dispatches. Either restores recovery; both are a counter and a compare.
    //
    // Until then this asserts what the hardware ACTUALLY does. When
    // exploration lands, this assertion flips -- deliberately, so the change
    // cannot go in silently.
    ui[7:6] = 2'b00;
    for (i = 0; i < 80; i++) begin
      wr(7'h01, 16, LARGE);
      go();
      result(eng, margin);
      if (eng == 3'd2) break;
      for (int w = 0; w < 4000; w++) begin
        rd(7'h09, 2, v);
        if (v[15:0] == 0) break;
      end
    end
    $display("fast profile after %0d dispatches: engine %0d (no recovery expected)", i, eng);
    if (eng === 3'd2) begin
      errors++;
      $display("FAIL: the decision recovered. If exploration or decay was just added, invert this check and update BUILDOUT.");
    end

    // ---- 5. a dispatch that waits for a busy engine (RTL-02) --------------
    // Reset clears calibration, so LARGE goes to the TPU again. With the TPU
    // slow, queue two LARGE jobs behind HOLD and release: the second waits
    // ~1500 cycles for the busy TPU. Nothing may be recorded as dispatched
    // until the crossbar actually takes it.
    rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; repeat (20) @(posedge clk);
    ui[7:6] = 2'b01;
    wr(7'h02, 1, 128'h01);             // HOLD
    wr(7'h01, 16, LARGE); go();
    wr(7'h01, 16, LARGE); go();
    wr(7'h03, 1, 128'h02);             // CLEAR_STICKY
    wr(7'h02, 1, 128'h00);             // release
    for (int w = 0; w < 4000; w++) begin
      rd(7'h09, 2, v);
      if (v[15:0] == 0) break;
    end
    ui[7:6] = 2'b00;
    $display("RTL-02: %0d dispatches recorded by the register block, %0d taken by the crossbar, %0d recorded early",
             obs_events, xbar_events, obs_early);
    if (obs_early != 0 || obs_events != xbar_events) begin
      errors++; $display("FAIL: dispatch observation does not follow the crossbar handshake");
    end

    // ---- 6. reads while dispatches land on their own (RTL-04) ---------------
    // Queue jobs behind a busy TPU and read RESULT back to back while they
    // dispatch without the host. Every 6-byte read must be a value RESULT
    // actually held at one instant.
    begin
      integer reads, torn, changes;
      rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; repeat (20) @(posedge clk);
      // Both the TPU and the vector unit slow; LARGE goes to the TPU and SMALL
      // to the vector unit, with different margins, so consecutive RESULTs
      // differ in every byte and a torn read cannot look like a real one.
      ui[7:6] = 2'b11;
      wr(7'h02, 1, 128'h01);
      for (int q = 0; q < 6; q++) begin wr(7'h01, 16, (q % 2) ? SMALL : LARGE); go(); end
      wr(7'h02, 1, 128'h00);
      reads = 0; torn = 0; changes = 0;
      for (int w = 0; w < 400; w++) begin
        n_seen = 0; sampling = 1;
        rd(7'h06, 6, v);
        sampling = 0;
        reads++;
        if (n_seen > 1) changes++;
        begin
          logic ok; ok = 0;
          for (int j = 0; j < n_seen; j++) if (seen_vals[j] === v[47:0]) ok = 1;
          if (!ok) begin
            torn++;
            if (torn < 3) $display("FAIL: RESULT read %012h, which the register never held during the read", v[47:0]);
          end
        end
        if (dut.obs_tag_busy == 8'h00 && w > 20) break;
      end
      ui[7:6] = 2'b00;
      $display("RTL-04: %0d RESULT reads, %0d of them while RESULT changed, %0d torn", reads, changes, torn);
      if (changes == 0) begin errors++; $display("FAIL: no read overlapped a dispatch; the test did not test anything"); end
      if (torn) begin errors++; $display("FAIL: multi-byte reads are not coherent"); end
    end

    // ---- 7. a host completion is refused here (RTL-08) --------------------
    // In this system the engines report their own completions. A COMP write
    // from the host used to be accepted and silently discarded; it must be a
    // FRAME_ERR so the host learns its completion went nowhere.
    wr(7'h03, 1, 128'h02);             // CLEAR_STICKY
    wr(7'h04, 1, 128'h00);             // COMP tag 0
    rd(7'h05, 2, v);
    $display("RTL-08: host COMP write -> status %04h", v[15:0]);
    if (!v[8]) begin errors++; $display("FAIL: a host completion was accepted and discarded without an error"); end

    if (errors) begin $display("FAIL tb_sys_tile: %0d errors", errors); $fatal(1); end
    $display("PASS tb_sys_tile");
    $finish;
  end
endmodule
`default_nettype wire
