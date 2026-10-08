// =============================================================================
// tb_measure.sv -- image bytes in, PCR out, against hashlib
// =============================================================================
// Seven images are measured in turn; after each, the image digest and the
// PCR are compared with hashlib. A start pulsed while the previous
// measurement is still being recorded must be refused, and the image
// measured after it must still land correctly.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_measure;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        start = 0, in_valid = 0, in_last = 0;
  logic [31:0] in_data = 0;
  logic [2:0]  in_bytes = 0;
  wire         start_ready, in_ready, busy, done, err;
  wire [255:0] image_digest, pcr;
  wire [15:0]  extend_count;

  hydra_measure dut (.clk(clk), .rst_n(rst_n), .start(start), .start_ready(start_ready),
    .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data), .in_bytes(in_bytes),
    .in_last(in_last), .busy(busy), .done(done), .err(err),
    .image_digest(image_digest), .pcr(pcr), .extend_count(extend_count));

  reg [31:0]  words [0:1023];
  integer     mlen [0:15], mnw [0:15], mlast [0:15];
  reg [255:0] edig [0:15], epcr [0:15];
  integer     n = 0, errors = 0, refused = 0;

  initial begin
    integer fd, code, a, b, c;
    reg [255:0] d, p;
    fd = $fopen("sec/tb/measure_meta.txt", "r");
    if (fd == 0) begin $display("FAIL: run measure_model.py first"); $fatal(1); end
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%d %d %d %h %h\n", a, b, c, d, p);
      if (code == 5) begin mlen[n] = a; mnw[n] = b; mlast[n] = c; edig[n] = d; epcr[n] = p; n = n + 1; end
    end
    $fclose(fd);
    $readmemh("sec/tb/measure_words.hex", words);
  end

  initial begin #20_000_000; $display("FAIL tb_measure: watchdog"); $fatal(1); end

  task automatic send(input [31:0] d, input [2:0] nb, input lst);
    @(negedge clk);
    in_valid = 1; in_data = d; in_bytes = nb; in_last = lst;
    @(posedge clk); while (!in_ready) @(posedge clk);
    @(negedge clk); in_valid = 0; in_last = 0;
  endtask

  integer m, i, base, guard;
  initial begin
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
    base = 0;
    for (m = 0; m < n; m = m + 1) begin
      while (!start_ready) @(negedge clk);
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      for (i = 0; i < mnw[m]; i = i + 1)
        send(words[base + i], (i == mnw[m] - 1) ? mlast[m][2:0] : 3'd4, i == mnw[m] - 1);

      // While the measurement is being recorded, a start must be refused.
      @(negedge clk);
      if (busy) begin
        if (start_ready) begin errors = errors + 1; $display("FAIL: start_ready while recording image %0d", m); end
        else refused = refused + 1;
      end

      guard = 0;
      while (!done && guard < 5000) begin @(negedge clk); guard = guard + 1; end
      if (guard >= 5000) begin errors = errors + 1; $display("FAIL image %0d (%0d bytes): never recorded", m, mlen[m]); end
      @(negedge clk);
      if (image_digest !== edig[m] || pcr !== epcr[m] || extend_count !== 16'(m + 1)) begin
        errors = errors + 1;
        $display("FAIL image %0d (%0d bytes): count %0d", m, mlen[m], extend_count);
        $display("   digest hw %064x", image_digest);
        $display("          py %064x", edig[m]);
        $display("   pcr    hw %064x", pcr);
        $display("          py %064x", epcr[m]);
      end
      base = base + mnw[m];
    end
    if (errors || err) begin $display("FAIL tb_measure: %0d errors", errors); $fatal(1); end
    $display("PASS tb_measure: %0d images (0 to 1000 bytes) measured into the PCR, identical to hashlib; start refused while recording (%0d checks)", n, refused);
    $finish;
  end
endmodule
`default_nettype wire
