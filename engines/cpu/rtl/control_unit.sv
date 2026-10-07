// control_unit.sv — RV32IM main decoder. Instruction in, ctrl_t bundle out.
`default_nettype none

module control_unit
    import asicirific_pkg::*;
#(
    parameter bit ENABLE_M = 1'b1     // RV32M multiply/divide present
)(
    input  wire logic [31:0] inst,
    output ctrl_t            ctrl
);
    wire logic [6:0] opc    = inst[6:0];
    wire logic [2:0] funct3 = inst[14:12];
    wire logic [6:0] funct7 = inst[31:25];
    wire logic       is_m   = (funct7 == 7'b0000001);

    always_comb begin
        // safe defaults = NOP-like
        ctrl = '0;
        ctrl.funct3  = funct3;
        ctrl.imm_sel = IMM_I;
        ctrl.alu_op  = ALU_ADD;
        ctrl.wb_sel  = WB_ALU;

        unique case (opc)
            OPC_LUI: begin
                ctrl.legal = 1; ctrl.rf_we = 1;
                ctrl.alu_op = ALU_COPY_B; ctrl.alu_b_imm = 1; ctrl.imm_sel = IMM_U;
            end
            OPC_AUIPC: begin
                ctrl.legal = 1; ctrl.rf_we = 1;
                ctrl.alu_a_pc = 1; ctrl.alu_b_imm = 1; ctrl.imm_sel = IMM_U;
            end
            OPC_JAL: begin
                ctrl.legal = 1; ctrl.rf_we = 1; ctrl.is_jal = 1;
                ctrl.wb_sel = WB_PC4; ctrl.imm_sel = IMM_J;
            end
            OPC_JALR: begin
                ctrl.legal = 1; ctrl.rf_we = 1; ctrl.is_jalr = 1;
                ctrl.wb_sel = WB_PC4; ctrl.imm_sel = IMM_I;
            end
            OPC_BRANCH: begin
                ctrl.legal = 1; ctrl.is_branch = 1; ctrl.imm_sel = IMM_B;
            end
            OPC_LOAD: begin
                ctrl.legal = 1; ctrl.rf_we = 1; ctrl.mem_read = 1;
                ctrl.wb_sel = WB_MEM; ctrl.alu_b_imm = 1; ctrl.imm_sel = IMM_I;
            end
            OPC_STORE: begin
                ctrl.legal = 1; ctrl.mem_write = 1;
                ctrl.alu_b_imm = 1; ctrl.imm_sel = IMM_S;
            end
            OPC_OPIMM: begin
                ctrl.legal = 1; ctrl.rf_we = 1; ctrl.alu_b_imm = 1; ctrl.imm_sel = IMM_I;
                unique case (funct3)
                    3'b000: ctrl.alu_op = ALU_ADD;
                    3'b010: ctrl.alu_op = ALU_SLT;
                    3'b011: ctrl.alu_op = ALU_SLTU;
                    3'b100: ctrl.alu_op = ALU_XOR;
                    3'b110: ctrl.alu_op = ALU_OR;
                    3'b111: ctrl.alu_op = ALU_AND;
                    3'b001: ctrl.alu_op = ALU_SLL;
                    3'b101: ctrl.alu_op = (inst[30]) ? ALU_SRA : ALU_SRL;
                    default: ctrl.legal = 0;
                endcase
            end
            OPC_OP: begin
                ctrl.legal = 1; ctrl.rf_we = 1;
                if (is_m) begin
                    // RV32M
                    ctrl.is_mul = ENABLE_M && (funct3[2] == 1'b0); // MUL/MULH/MULHSU/MULHU
                    ctrl.is_div = ENABLE_M && (funct3[2] == 1'b1); // DIV/DIVU/REM/REMU
                    ctrl.legal  = ENABLE_M;                        // M op illegal if disabled
                end else begin
                    unique case (funct3)
                        3'b000: ctrl.alu_op = (inst[30]) ? ALU_SUB : ALU_ADD;
                        3'b010: ctrl.alu_op = ALU_SLT;
                        3'b011: ctrl.alu_op = ALU_SLTU;
                        3'b100: ctrl.alu_op = ALU_XOR;
                        3'b110: ctrl.alu_op = ALU_OR;
                        3'b111: ctrl.alu_op = ALU_AND;
                        3'b001: ctrl.alu_op = ALU_SLL;
                        3'b101: ctrl.alu_op = (inst[30]) ? ALU_SRA : ALU_SRL;
                        default: ctrl.legal = 0;
                    endcase
                end
            end
            OPC_SYSTEM: begin
                if (funct3 != 3'b000) begin
                    ctrl.legal = 1; ctrl.rf_we = 1; ctrl.is_csr = 1;
                    ctrl.wb_sel = WB_CSR;
                    ctrl.csr_use_imm = funct3[2];
                end
                // ECALL/EBREAK decode as legal NOPs for now (trap unit is Phase 2b)
                else ctrl.legal = 1;
            end
            OPC_FENCE: ctrl.legal = 1; // NOP
            default:   ctrl.legal = 0;
        endcase
    end
endmodule : control_unit
