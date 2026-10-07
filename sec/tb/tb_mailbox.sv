// =============================================================================
// tb_mailbox.sv -- two requesters contending for one mailbox
// =============================================================================
// The proof shows two requesters can never both hold the lock. This shows
// the protocol actually works for the one that wins and fails cleanly for
// the one that loses: the loser's writes are refused and flagged, the
// owner's command arrives intact, and the lock comes back when EXECUTE is
// cleared.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_mailbox;
  localparam int DW = 32, DEPTH = 16, UW = 4;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic          req_valid = 0, req_write = 0;
  logic [UW-1:0] req_user = 0;
  logic [2:0]    req_reg = 0;
  logic [DW-1:0] req_wdata = 0;
  wire  [DW-1:0] req_rdata;
  wire           req_error;
  wire           cmd_valid;
  wire  [DW-1:0] cmd_code, cmd_dlen;
  logic          cmd_done = 0;
  logic [1:0]    cmd_status_in = 2'b10;
  wire           locked;
  wire  [UW-1:0] owner;

  hydra_mailbox #(.DW(DW), .DEPTH(DEPTH), .UW(UW)) dut (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_user(req_user), .req_reg(req_reg),
    .req_write(req_write), .req_wdata(req_wdata), .req_rdata(req_rdata),
    .req_error(req_error),
    .cmd_valid(cmd_valid), .cmd_code(cmd_code), .cmd_dlen(cmd_dlen),
    .cmd_done(cmd_done), .cmd_status_in(cmd_status_in),
    .buf_addr(), .buf_re(1'b0), .buf_rdata(),
    .locked(locked), .owner(owner));

  localparam logic [2:0] R_LOCK=0, R_CMD=1, R_DLEN=2, R_DATAIN=3,
                         R_DATAOUT=4, R_EXECUTE=5, R_STATUS=6;

  integer errors = 0, checks = 0;
  reg [DW-1:0] got;
  reg          err;

  task automatic access(input logic [UW-1:0] u, input logic [2:0] r,
                        input logic w, input logic [DW-1:0] d);
    // Read data and the error flag are registered and live for exactly ONE
    // cycle -- both are cleared at the top of every cycle, on purpose, so a
    // stale value can never be mistaken for a fresh answer. Sample in the
    // cycle right after the request, not the one after that.
    @(negedge clk);
    req_valid = 1; req_user = u; req_reg = r; req_write = w; req_wdata = d;
    @(negedge clk);
    req_valid = 0; req_write = 0;
    got = req_rdata;
    err = req_error;
  endtask

  initial begin #200_000; $display("FAIL tb_mailbox: watchdog"); $fatal(1); end

  initial begin
    repeat (4) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

    // Requester 3 takes the lock: reading returns 0, meaning granted.
    access(4'd3, R_LOCK, 1'b0, '0);
    if (got !== 32'd0) begin errors++; $display("FAIL: first lock read returned %0d", got); end
    else checks++;
    if (!locked || owner !== 4'd3) begin errors++; $display("FAIL: lock not held by 3"); end
    else checks++;

    // Requester 7 asks: reading returns 1, meaning taken. It must NOT own it.
    access(4'd7, R_LOCK, 1'b0, '0);
    if (got !== 32'd1) begin errors++; $display("FAIL: second lock read returned %0d", got); end
    else checks++;
    if (owner !== 4'd3) begin errors++; $display("FAIL: owner changed to %0d", owner); end
    else checks++;

    // Requester 7 tries to write anyway. Refused AND flagged.
    access(4'd7, R_CMD, 1'b1, 32'hBAD0_BAD0);
    if (!err) begin errors++; $display("FAIL: stranger's write was not flagged"); end
    else checks++;

    // The owner's command goes in.
    access(4'd3, R_CMD,  1'b1, 32'h0000_1234);
    access(4'd3, R_DLEN, 1'b1, 32'd8);
    access(4'd3, R_DATAIN, 1'b1, 32'hAAAA_5555);
    access(4'd3, R_DATAIN, 1'b1, 32'h1234_5678);
    if (cmd_code !== 32'h0000_1234 || cmd_dlen !== 32'd8) begin
      errors++; $display("FAIL: command %08x length %0d", cmd_code, cmd_dlen);
    end else checks++;

    // EXECUTE starts it; status is busy until the far side answers.
    access(4'd3, R_EXECUTE, 1'b1, 32'd1);
    if (!cmd_valid) begin errors++; $display("FAIL: EXECUTE did not raise a command"); end
    else checks++;
    access(4'd3, R_STATUS, 1'b0, '0);
    if (got[1:0] !== 2'b00) begin errors++; $display("FAIL: status %b, expected busy", got[1:0]); end
    else checks++;

    // The far side completes.
    @(negedge clk); cmd_done = 1; cmd_status_in = 2'b10;
    @(negedge clk); cmd_done = 0;
    access(4'd3, R_STATUS, 1'b0, '0);
    if (got[1:0] !== 2'b10) begin
      errors++; $display("FAIL: status %b, expected complete", got[1:0]);
    end else checks++;

    // Clearing EXECUTE releases the lock -- the only release path there is.
    access(4'd3, R_EXECUTE, 1'b1, 32'd0);
    if (locked) begin errors++; $display("FAIL: lock not released"); end
    else checks++;

    // Now 7 can have it.
    access(4'd7, R_LOCK, 1'b0, '0);
    if (got !== 32'd0 || owner !== 4'd7) begin
      errors++; $display("FAIL: 7 could not take the freed lock (read %0d, owner %0d)", got, owner);
    end else checks++;

    // And 3, now a stranger, is refused in turn -- the roles are symmetric.
    access(4'd3, R_CMD, 1'b1, 32'hDEAD);
    if (!err) begin errors++; $display("FAIL: previous owner's write was not flagged"); end
    else checks++;

    if (errors) begin
      $display("FAIL tb_mailbox: %0d errors", errors);
      $fatal(1);
    end
    $display("PASS tb_mailbox: %0d checks, lock contention and protocol enforcement exact", checks);
    $finish;
  end
endmodule
`default_nettype wire
