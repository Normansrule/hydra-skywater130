// =============================================================================
// tb_secure_boot.sv -- hydra_secure_boot against hashlib (secure_boot_model.py)
// =============================================================================
// A memory with the CPU's read timing (data one cycle after the address) holds
// the image. The bench boots a tampered image, a zero length, a length past
// the memory, the real image, and then tries again; every digest, PCR, flag
// and lock is compared with the model. It also checks, every clock, that the
// load lock is up for the whole of every boot and never drops after VERIFIED.
//   +dir=<model output dir>      GOLDEN: compile-time parameter from the model
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_secure_boot;
  parameter logic [255:0] GOLDEN = 256'd0;
  localparam int AW = 10;                      // 1,024 words: small enough to run fast

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] mem [0:(1<<AW)-1];
  logic        start = 0;
  logic [AW:0] len = 0;
  wire  [AW-1:0] rd_addr;
  logic [31:0] rd_data;
  wire         busy, verified, failed, lock_load, lock_debug;
  wire [255:0] digest, pcr;
  wire [15:0]  boots;

  always_ff @(posedge clk) rd_data <= mem[rd_addr];

  hydra_secure_boot #(.GOLDEN(GOLDEN), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n), .boot_start(start), .boot_len(len),
    .rd_addr(rd_addr), .rd_data(rd_data),
    .busy(busy), .verified(verified), .failed(failed),
    .lock_load(lock_load), .lock_debug(lock_debug),
    .digest(digest), .pcr(pcr), .boots(boots));

  int errors = 0, checks = 0;
  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin errors++; if (errors < 20) $display("FAIL: %s", what); end
  endtask
  initial begin #50_000_000; $display("FAIL tb_secure_boot: watchdog"); $fatal(1); end

  // invariants on every clock
  logic seen_verified = 0;
  always @(posedge clk) if (rst_n) begin
    if (busy && !lock_load) begin errors++; $display("FAIL: host load port open during a boot at %0t", $time); end
    if (verified) seen_verified <= 1'b1;
    if (seen_verified && !(verified && lock_load && lock_debug)) begin
      errors++; $display("FAIL: VERIFIED or a lock dropped after a verified boot at %0t", $time);
    end
  end

  task automatic boot(input logic [AW:0] n);
    @(negedge clk); len = n; start = 1;
    @(negedge clk); start = 0;
    while (busy) @(negedge clk);
    @(negedge clk);
  endtask

  string dir;
  int fd, r, nwords, tw, tb;
  logic [255:0] g, d_bad, pcr1, pcr4;
  logic [255:0] dig_v, pcr_v;
  logic [15:0]  boots_v;

  initial begin
    if (!$value$plusargs("dir=%s", dir)) begin $display("FAIL: +dir= not given"); $fatal(1); end
    for (int i = 0; i < (1 << AW); i++) mem[i] = 32'hFFFF_FFFF;
    $readmemh({dir, "/sb_image.hex"}, mem);
    fd = $fopen({dir, "/sb_meta.txt"}, "r");
    r = $fscanf(fd, "%d %d %d %h %h %h %h", nwords, tw, tb, g, d_bad, pcr1, pcr4);
    $fclose(fd);
    check(g == GOLDEN, "GOLDEN parameter differs from the model's digest of the image");
    repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

    check(!verified && !failed && !busy && !lock_load && !lock_debug, "not idle and open after reset");

    // 1. one bit changed: hashed, refused, recorded
    mem[tw][8*tb] = ~mem[tw][8*tb];
    boot((AW+1)'(nwords));
    check(failed && !verified, "a tampered image was not refused");
    check(digest == d_bad, $sformatf("tampered digest %h, model %h", digest, d_bad));
    check(pcr == pcr1, "PCR after the tampered boot differs from the model");
    check(!lock_load && !lock_debug, "ports locked after a FAILED boot: the host must be able to reload");
    mem[tw][8*tb] = ~mem[tw][8*tb];             // the host loads the right image

    // 2, 3. lengths refused before anything is read
    boot('0);
    check(failed && !verified && pcr == pcr1, "a zero-length boot was not refused, or it changed the PCR");
    boot((AW+1)'((1 << AW) + 1));
    check(failed && !verified && pcr == pcr1, "a boot longer than the memory was not refused, or it changed the PCR");
    check(boots == 16'd3, $sformatf("boot counter %0d after three boots", boots));

    // 4. the real image
    boot((AW+1)'(nwords));
    check(verified && !failed, "the real image was not verified");
    check(digest == g, $sformatf("digest %h, model %h", digest, g));
    check(pcr == pcr4, "PCR after the verified boot differs from the model");
    check(lock_load && lock_debug, "ports not locked after VERIFIED");

    // 5. after VERIFIED nothing can re-run a boot or change the record
    dig_v = digest; pcr_v = pcr; boots_v = boots;
    mem[0] = ~mem[0];
    @(negedge clk); len = (AW+1)'(nwords); start = 1;
    @(negedge clk); start = 0;
    repeat (20) @(negedge clk);
    check(!busy && verified && digest == dig_v && pcr == pcr_v && boots == boots_v,
          "a boot started after VERIFIED ran or changed the record");

    if (errors) begin $display("FAIL tb_secure_boot: %0d of %0d checks", errors, checks); $fatal(1); end
    $display("PASS tb_secure_boot: %0d checks; %0d-word image, tampered byte refused, bad lengths refused, real image verified, digests and PCR equal to hashlib, ports locked",
             checks, nwords);
    $finish;
  end
endmodule
`default_nettype wire
