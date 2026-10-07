// =============================================================================
// tb_xsec_unit.sv -- the security instructions against the reference model
// =============================================================================
// 231 vectors: the four Zknh helpers on random and boundary operands (the
// boundaries exercise both halves of the RV64 rule -- upper rs1 bits
// ignored, result sign-extended), constant-time equality, privilege
// trapping in user, supervisor and machine mode, and the reserved encoding.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_xsec_unit;
  reg  [31:0] insn; reg [63:0] rs1, rs2; reg [1:0] priv;
  wire claim, illegal, rd_we; wire [63:0] rd_val;
  wire kv_we, kv_lock, meas_we, pcr_extend;

  hydra_xsec_unit dut (
    .valid(1'b1), .insn(insn), .rs1(rs1), .rs2(rs2), .priv(priv),
    .claim(claim), .illegal(illegal), .rd_we(rd_we), .rd_val(rd_val),
    .kv_we(kv_we), .kv_slot(), .kv_word(), .kv_wdata(), .kv_lock(kv_lock),
    .kv_rd_slot(), .kv_rdata(32'h0000_0003),
    .meas_we(meas_we), .meas_word(), .meas_wdata(), .pcr_extend(pcr_extend),
    .pcr_value(256'd0));

  integer fd, code, n = 0, errors = 0;
  reg [31:0] i; reg [63:0] a, b, r; integer p, we, ill;

  initial begin
    fd = $fopen("isa/tb/xsec_vectors.txt", "r");
    if (fd == 0) begin $display("FAIL: run xsec_model.py first"); $fatal(1); end
    while (!$feof(fd)) begin
      code = $fscanf(fd, "%h %h %h %d %d %h %d\n", i, a, b, p, we, r, ill);
      if (code == 7) begin
        insn = i; rs1 = a; rs2 = b; priv = p[1:0];
        #1;
        if (illegal !== ill[0] || (!ill && (rd_we !== we[0] || (we && rd_val !== r)))) begin
          errors = errors + 1;
          if (errors < 8)
            $display("FAIL insn %08x rs1 %016x priv %0d: rd %016x we %b ill %b, model rd %016x we %0d ill %0d",
                     i, a, p, rd_val, rd_we, illegal, r, we, ill);
        end
        // A trapped key operation must not have reached the vault.
        if (ill && (kv_we || kv_lock)) begin
          errors = errors + 1;
          $display("FAIL insn %08x priv %0d: trapped, yet the vault was written", i, p);
        end
        n = n + 1;
      end
    end
    if (errors) begin $display("FAIL tb_xsec_unit: %0d of %0d vectors", errors, n); $fatal(1); end
    $display("PASS tb_xsec_unit: %0d vectors exact -- Zknh, constant-time compare, privilege traps", n);
    $finish;
  end
endmodule
`default_nettype wire
