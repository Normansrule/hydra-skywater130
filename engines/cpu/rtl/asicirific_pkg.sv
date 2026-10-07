// asicirific_pkg.sv — shared types for the ASICirific RV32IM core
// One package, imported everywhere. Keep ISA constants here only.
`default_nettype none

package asicirific_pkg;

    // RV32 base opcodes (inst[6:0])
    localparam logic [6:0] OPC_LUI    = 7'b0110111;
    localparam logic [6:0] OPC_AUIPC  = 7'b0010111;
    localparam logic [6:0] OPC_JAL    = 7'b1101111;
    localparam logic [6:0] OPC_JALR   = 7'b1100111;
    localparam logic [6:0] OPC_BRANCH = 7'b1100011;
    localparam logic [6:0] OPC_LOAD   = 7'b0000011;
    localparam logic [6:0] OPC_STORE  = 7'b0100011;
    localparam logic [6:0] OPC_OPIMM  = 7'b0010011;
    localparam logic [6:0] OPC_OP     = 7'b0110011;
    localparam logic [6:0] OPC_SYSTEM = 7'b1110011;
    localparam logic [6:0] OPC_FENCE  = 7'b0001111;

    // ALU operations
    typedef enum logic [3:0] {
        ALU_ADD  = 4'd0,
        ALU_SUB  = 4'd1,
        ALU_AND  = 4'd2,
        ALU_OR   = 4'd3,
        ALU_XOR  = 4'd4,
        ALU_SLT  = 4'd5,
        ALU_SLTU = 4'd6,
        ALU_SLL  = 4'd7,
        ALU_SRL  = 4'd8,
        ALU_SRA  = 4'd9,
        ALU_COPY_B = 4'd10,   // LUI
        ALU_CSR_CLR = 4'd11   // rs1 & ~rs2 for CSRRC
    } alu_op_t;

    // Immediate formats
    typedef enum logic [2:0] {
        IMM_I = 3'd0,
        IMM_S = 3'd1,
        IMM_B = 3'd2,
        IMM_U = 3'd3,
        IMM_J = 3'd4
    } imm_sel_t;

    // Branch comparator result bundle
    typedef struct packed {
        logic eq;
        logic lt;   // signed
        logic ltu;  // unsigned
    } br_cmp_t;

    // Writeback source
    typedef enum logic [1:0] {
        WB_ALU = 2'd0,
        WB_MEM = 2'd1,
        WB_PC4 = 2'd2,
        WB_CSR = 2'd3
    } wb_sel_t;

    // Decoded control bundle (one instruction's control signals)
    typedef struct packed {
        logic     legal;
        logic     rf_we;        // writes rd
        wb_sel_t  wb_sel;
        alu_op_t  alu_op;
        logic     alu_a_pc;     // ALU A = PC (AUIPC/JAL/branch target calc)
        logic     alu_b_imm;    // ALU B = immediate
        imm_sel_t imm_sel;
        logic     is_branch;
        logic     is_jal;
        logic     is_jalr;
        logic     mem_read;
        logic     mem_write;
        logic [2:0] funct3;
        logic     is_csr;
        logic     csr_use_imm;  // CSRRxI
        logic     is_mul;
        logic     is_div;
    } ctrl_t;

endpackage : asicirific_pkg

