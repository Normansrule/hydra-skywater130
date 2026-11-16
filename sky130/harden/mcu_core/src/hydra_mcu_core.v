`default_nettype none
`default_nettype wire
`default_nettype none
`default_nettype wire
`default_nettype none
`default_nettype wire
`default_nettype none
`default_nettype wire
`default_nettype none
`default_nettype wire
`default_nettype none
module ParallelPrefixAdder (
	A,
	B,
	CARRY_IN,
	SUM,
	CARRY_OUT
);
	parameter signed [31:0] WIDTH = 64;
	input wire [WIDTH - 1:0] A;
	input wire [WIDTH - 1:0] B;
	input wire CARRY_IN;
	output wire [WIDTH - 1:0] SUM;
	output wire CARRY_OUT;
	localparam signed [31:0] LEVELS = $clog2(WIDTH + 1);
	wire [WIDTH - 1:0] BIT_PROPAGATE;
	assign BIT_PROPAGATE = A ^ B;
	genvar _gv_LEVEL_1;
	genvar _gv_BIT_INDEX_1;
	generate
		for (_gv_LEVEL_1 = 0; _gv_LEVEL_1 <= LEVELS; _gv_LEVEL_1 = _gv_LEVEL_1 + 1) begin : prefix_level
			localparam LEVEL = _gv_LEVEL_1;
			wire [WIDTH:0] GENERATE;
			wire [WIDTH:0] PROPAGATE;
			if (LEVEL == 0) begin : inputs
				assign GENERATE = {A & B, CARRY_IN};
				assign PROPAGATE = {BIT_PROPAGATE, 1'b0};
			end
			else begin : combine_level
				localparam signed [31:0] DISTANCE = 1 << (LEVEL - 1);
				for (_gv_BIT_INDEX_1 = 0; _gv_BIT_INDEX_1 <= WIDTH; _gv_BIT_INDEX_1 = _gv_BIT_INDEX_1 + 1) begin : prefix_bit
					localparam BIT_INDEX = _gv_BIT_INDEX_1;
					if (BIT_INDEX >= DISTANCE) begin : combine
						assign GENERATE[BIT_INDEX] = prefix_level[LEVEL - 1].GENERATE[BIT_INDEX] | (prefix_level[LEVEL - 1].PROPAGATE[BIT_INDEX] & prefix_level[LEVEL - 1].GENERATE[BIT_INDEX - DISTANCE]);
						assign PROPAGATE[BIT_INDEX] = prefix_level[LEVEL - 1].PROPAGATE[BIT_INDEX] & prefix_level[LEVEL - 1].PROPAGATE[BIT_INDEX - DISTANCE];
					end
					else begin : pass
						assign GENERATE[BIT_INDEX] = prefix_level[LEVEL - 1].GENERATE[BIT_INDEX];
						assign PROPAGATE[BIT_INDEX] = prefix_level[LEVEL - 1].PROPAGATE[BIT_INDEX];
					end
				end
			end
		end
	endgenerate
	assign SUM = BIT_PROPAGATE ^ prefix_level[LEVELS].GENERATE[WIDTH - 1:0];
	assign CARRY_OUT = prefix_level[LEVELS].GENERATE[WIDTH];
endmodule
`default_nettype wire
`default_nettype none
module PrefixNegate (
	X,
	NEGATED
);
	parameter signed [31:0] WIDTH = 64;
	input wire [WIDTH - 1:0] X;
	output wire [WIDTH - 1:0] NEGATED;
	localparam signed [31:0] LEVELS = $clog2(WIDTH);
	genvar _gv_LEVEL_2;
	genvar _gv_BIT_INDEX_2;
	generate
		for (_gv_LEVEL_2 = 0; _gv_LEVEL_2 <= LEVELS; _gv_LEVEL_2 = _gv_LEVEL_2 + 1) begin : or_level
			localparam LEVEL = _gv_LEVEL_2;
			wire [WIDTH - 1:0] ANY_SET;
			if (LEVEL == 0) begin : inputs
				assign ANY_SET = X;
			end
			else begin : combine_level
				localparam signed [31:0] DISTANCE = 1 << (LEVEL - 1);
				for (_gv_BIT_INDEX_2 = 0; _gv_BIT_INDEX_2 < WIDTH; _gv_BIT_INDEX_2 = _gv_BIT_INDEX_2 + 1) begin : or_bit
					localparam BIT_INDEX = _gv_BIT_INDEX_2;
					if (BIT_INDEX >= DISTANCE) begin : combine
						assign ANY_SET[BIT_INDEX] = or_level[LEVEL - 1].ANY_SET[BIT_INDEX] | or_level[LEVEL - 1].ANY_SET[BIT_INDEX - DISTANCE];
					end
					else begin : pass
						assign ANY_SET[BIT_INDEX] = or_level[LEVEL - 1].ANY_SET[BIT_INDEX];
					end
				end
			end
		end
	endgenerate
	assign NEGATED = X ^ {or_level[LEVELS].ANY_SET[WIDTH - 2:0], 1'b0};
endmodule
`default_nettype wire
`default_nettype none
module LeadingZeroCounter (
	X,
	COUNT,
	ALL_ZERO
);
	input wire [63:0] X;
	output wire [5:0] COUNT;
	output wire ALL_ZERO;
	genvar _gv_LEVEL_3;
	genvar _gv_BLOCK_1;
	generate
		for (_gv_LEVEL_3 = 1; _gv_LEVEL_3 <= 6; _gv_LEVEL_3 = _gv_LEVEL_3 + 1) begin : zero_count
			localparam LEVEL = _gv_LEVEL_3;
			localparam signed [31:0] BLOCKS = 64 >> LEVEL;
			wire [BLOCKS - 1:0] BLOCK_ALL_ZERO;
			wire [LEVEL - 1:0] BLOCK_COUNT [0:BLOCKS - 1];
			for (_gv_BLOCK_1 = 0; _gv_BLOCK_1 < BLOCKS; _gv_BLOCK_1 = _gv_BLOCK_1 + 1) begin : block
				localparam BLOCK = _gv_BLOCK_1;
				if (LEVEL == 1) begin : pair_of_bits
					assign BLOCK_ALL_ZERO[BLOCK] = ~X[(2 * BLOCK) + 1] & ~X[2 * BLOCK];
					assign BLOCK_COUNT[BLOCK] = ~X[(2 * BLOCK) + 1];
				end
				else begin : pair_of_blocks
					wire UPPER_ZERO;
					assign UPPER_ZERO = zero_count[LEVEL - 1].BLOCK_ALL_ZERO[(2 * BLOCK) + 1];
					assign BLOCK_ALL_ZERO[BLOCK] = UPPER_ZERO & zero_count[LEVEL - 1].BLOCK_ALL_ZERO[2 * BLOCK];
					assign BLOCK_COUNT[BLOCK] = (UPPER_ZERO ? {1'b1, zero_count[LEVEL - 1].BLOCK_COUNT[2 * BLOCK]} : {1'b0, zero_count[LEVEL - 1].BLOCK_COUNT[(2 * BLOCK) + 1]});
				end
			end
		end
	endgenerate
	assign COUNT = zero_count[6].BLOCK_COUNT[0];
	assign ALL_ZERO = zero_count[6].BLOCK_ALL_ZERO[0];
endmodule
`default_nettype wire
`default_nettype none
module PopulationCount (
	X,
	QUARTER_COUNTS
);
	reg _sv2v_0;
	input wire [63:0] X;
	output reg [19:0] QUARTER_COUNTS;
	function automatic [2:0] nibble_count;
		input reg [3:0] n;
		reg at_least_two;
		begin
			at_least_two = (((((n[0] & n[1]) | (n[0] & n[2])) | (n[0] & n[3])) | (n[1] & n[2])) | (n[1] & n[3])) | (n[2] & n[3]);
			nibble_count = {&n, at_least_two & ~(&n), ^n};
		end
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] quarter;
			for (quarter = 0; quarter < 4; quarter = quarter + 1)
				begin
					QUARTER_COUNTS[5 * quarter+:5] = 5'd0;
					begin : sv2v_autoblock_2
						reg signed [31:0] nibble;
						for (nibble = 0; nibble < 4; nibble = nibble + 1)
							QUARTER_COUNTS[5 * quarter+:5] = QUARTER_COUNTS[5 * quarter+:5] + {2'd0, nibble_count(X[(16 * quarter) + (4 * nibble)+:4])};
					end
				end
		end
	end
	initial _sv2v_0 = 0;
endmodule
module PopulationCountFinish (
	QUARTER_COUNTS,
	WORD,
	COUNT
);
	input wire [19:0] QUARTER_COUNTS;
	input wire WORD;
	output wire [6:0] COUNT;
	wire [5:0] LOW_HALF;
	wire [5:0] HIGH_HALF;
	assign LOW_HALF = {1'b0, QUARTER_COUNTS[4:0]} + {1'b0, QUARTER_COUNTS[9:5]};
	assign HIGH_HALF = (WORD ? 6'd0 : {1'b0, QUARTER_COUNTS[14:10]} + {1'b0, QUARTER_COUNTS[19:15]});
	assign COUNT = {1'b0, LOW_HALF} + {1'b0, HIGH_HALF};
endmodule
`default_nettype wire
`default_nettype none
module ALU (
	A,
	B,
	ALUop,
	SUBTRACT_MODE,
	ALU_IS_WORD_OPERATION,
	LATE_RESULT,
	ALUOutFast,
	ALUOut
);
	reg _sv2v_0;
	input wire [63:0] A;
	input wire [63:0] B;
	input wire [5:0] ALUop;
	input wire SUBTRACT_MODE;
	input wire ALU_IS_WORD_OPERATION;
	input wire LATE_RESULT;
	output reg [63:0] ALUOutFast;
	output reg [63:0] ALUOut;
	wire [63:0] ADDER_SUM;
	wire ADDER_CARRY_OUT;
	ParallelPrefixAdder #(.WIDTH(64)) shared_adder(
		.A(A),
		.B((SUBTRACT_MODE ? ~B : B)),
		.CARRY_IN(SUBTRACT_MODE),
		.SUM(ADDER_SUM),
		.CARRY_OUT(ADDER_CARRY_OUT)
	);
	wire [63:0] CLZ_INPUT;
	reg [63:0] CTZ_INPUT_REVERSED;
	wire [5:0] CLZ_COUNT;
	wire [5:0] CTZ_COUNT;
	wire CLZ_ALL_ZERO;
	wire CTZ_ALL_ZERO;
	wire [19:0] QUARTER_POPULATIONS;
	wire [63:0] CTZ_INPUT;
	assign CLZ_INPUT = (ALU_IS_WORD_OPERATION ? {A[31:0], 32'hffffffff} : A);
	assign CTZ_INPUT = (ALU_IS_WORD_OPERATION ? {32'hffffffff, A[31:0]} : A);
	always @(*) begin : sv2v_autoblock_1
		reg signed [31:0] i;
		if (_sv2v_0)
			;
		for (i = 0; i < 64; i = i + 1)
			CTZ_INPUT_REVERSED[i] = CTZ_INPUT[63 - i];
	end
	LeadingZeroCounter count_leading(
		.X(CLZ_INPUT),
		.COUNT(CLZ_COUNT),
		.ALL_ZERO(CLZ_ALL_ZERO)
	);
	LeadingZeroCounter count_trailing(
		.X(CTZ_INPUT_REVERSED),
		.COUNT(CTZ_COUNT),
		.ALL_ZERO(CTZ_ALL_ZERO)
	);
	PopulationCount count_ones(
		.X(A),
		.QUARTER_COUNTS(QUARTER_POPULATIONS)
	);
	wire [63:0] CLZ_RESULT;
	wire [63:0] CTZ_RESULT;
	wire [63:0] CPOP_RESULT;
	assign CLZ_RESULT = (CLZ_ALL_ZERO ? 64'd64 : {58'd0, CLZ_COUNT});
	assign CTZ_RESULT = (CTZ_ALL_ZERO ? 64'd64 : {58'd0, CTZ_COUNT});
	assign CPOP_RESULT = {44'd0, QUARTER_POPULATIONS};
	function automatic [63:0] ror64;
		input reg [63:0] x;
		input reg signed [31:0] n;
		ror64 = (x >> n) | (x << (64 - n));
	endfunction
	function automatic [31:0] ror32;
		input reg [31:0] x;
		input reg signed [31:0] n;
		ror32 = (x >> n) | (x << (32 - n));
	endfunction
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	function automatic [63:0] alu;
		input reg [63:0] rs1;
		input reg [63:0] rs2;
		input reg [5:0] operation_code;
		input reg is_word;
		input reg [64:0] add_and_subtract_result;
		input reg [63:0] clz_result;
		input reg [63:0] ctz_result;
		input reg [63:0] cpop_result;
		reg signed [63:0] signed_rs1;
		reg [5:0] bit_shift;
		reg [4:0] word_bit_shift;
		reg [63:0] and_result;
		reg [63:0] or_result;
		reg [63:0] xor_result;
		reg [63:0] csr_result;
		reg [31:0] sha256_sum0;
		reg [31:0] sha256_sum1;
		reg [31:0] sha256_sig0;
		reg [31:0] sha256_sig1;
		reg [63:0] sll_result;
		reg [63:0] sra_result;
		reg [63:0] srl_result;
		reg [127:0] rotate_left_wide;
		reg [127:0] rotate_right_wide;
		reg [63:0] word_doubled;
		reg [31:0] word_sll_result;
		reg [31:0] word_srl_result;
		reg [31:0] word_sra_result;
		reg [31:0] word_rol_result;
		reg [31:0] word_ror_result;
		reg [63:0] rev8_result;
		reg [63:0] orc_b_result;
		reg slt_result;
		reg sltu_result;
		reg [63:0] alu_result;
		reg [31:0] word_result;
		begin
			signed_rs1 = $signed(rs1);
			bit_shift = rs2[5:0];
			word_bit_shift = rs2[4:0];
			sha256_sum0 = (ror32(rs1[31:0], 2) ^ ror32(rs1[31:0], 13)) ^ ror32(rs1[31:0], 22);
			sha256_sum1 = (ror32(rs1[31:0], 6) ^ ror32(rs1[31:0], 11)) ^ ror32(rs1[31:0], 25);
			sha256_sig0 = (ror32(rs1[31:0], 7) ^ ror32(rs1[31:0], 18)) ^ (rs1[31:0] >> 3);
			sha256_sig1 = (ror32(rs1[31:0], 17) ^ ror32(rs1[31:0], 19)) ^ (rs1[31:0] >> 10);
			and_result = rs1 & rs2;
			or_result = rs1 | rs2;
			xor_result = rs1 ^ rs2;
			csr_result = rs1 & ~rs2;
			sll_result = rs1 << bit_shift;
			sra_result = signed_rs1 >>> bit_shift;
			srl_result = rs1 >> bit_shift;
			rotate_left_wide = {rs1, rs1} << bit_shift;
			rotate_right_wide = {rs1, rs1} >> bit_shift;
			word_doubled = {rs1[31:0], rs1[31:0]};
			word_sll_result = rs1[31:0] << word_bit_shift;
			word_srl_result = rs1[31:0] >> word_bit_shift;
			word_sra_result = $signed(rs1[31:0]) >>> word_bit_shift;
			word_rol_result = sv2v_cast_32((word_doubled << word_bit_shift) >> 32);
			word_ror_result = sv2v_cast_32(word_doubled >> word_bit_shift);
			begin : sv2v_autoblock_2
				reg signed [31:0] i;
				for (i = 0; i < 8; i = i + 1)
					begin
						rev8_result[8 * i+:8] = rs1[8 * (7 - i)+:8];
						orc_b_result[8 * i+:8] = {8 {|rs1[8 * i+:8]}};
					end
			end
			slt_result = (rs1[63] != rs2[63] ? rs1[63] : add_and_subtract_result[63]);
			sltu_result = ~add_and_subtract_result[64];
			alu_result = 64'd0;
			(* full_case, parallel_case *)
			case (operation_code)
				6'd0: alu_result = add_and_subtract_result[63:0];
				6'd1: alu_result = add_and_subtract_result[63:0];
				6'd2: alu_result = and_result;
				6'd3: alu_result = or_result;
				6'd4: alu_result = xor_result;
				6'd5: alu_result = {63'd0, slt_result};
				6'd6: alu_result = {63'd0, sltu_result};
				6'd7: alu_result = sll_result;
				6'd8: alu_result = sra_result;
				6'd9: alu_result = srl_result;
				6'd10: alu_result = rs2;
				6'd11: alu_result = csr_result;
				6'd12: alu_result = add_and_subtract_result[63:0];
				6'd32: alu_result = (slt_result ? rs1 : rs2);
				6'd33: alu_result = (sltu_result ? rs1 : rs2);
				6'd34: alu_result = (slt_result ? rs2 : rs1);
				6'd35: alu_result = (sltu_result ? rs2 : rs1);
				6'd39: alu_result = rotate_left_wide[127:64];
				6'd40: alu_result = rotate_right_wide[63:0];
				6'd36: alu_result = clz_result;
				6'd37: alu_result = ctz_result;
				6'd38: alu_result = cpop_result;
				6'd41: alu_result = {{56 {rs1[7]}}, rs1[7:0]};
				6'd42: alu_result = {{48 {rs1[15]}}, rs1[15:0]};
				6'd43: alu_result = {48'd0, rs1[15:0]};
				6'd44: alu_result = rev8_result;
				6'd45: alu_result = orc_b_result;
				6'd46: alu_result = {63'd0, srl_result[0]};
				6'd47: alu_result = {{32 {sha256_sum0[31]}}, sha256_sum0};
				6'd48: alu_result = {{32 {sha256_sum1[31]}}, sha256_sum1};
				6'd49: alu_result = {{32 {sha256_sig0[31]}}, sha256_sig0};
				6'd50: alu_result = {{32 {sha256_sig1[31]}}, sha256_sig1};
				6'd51: alu_result = (ror64(rs1, 28) ^ ror64(rs1, 34)) ^ ror64(rs1, 39);
				6'd52: alu_result = (ror64(rs1, 14) ^ ror64(rs1, 18)) ^ ror64(rs1, 41);
				6'd53: alu_result = (ror64(rs1, 1) ^ ror64(rs1, 8)) ^ (rs1 >> 7);
				6'd54: alu_result = (ror64(rs1, 19) ^ ror64(rs1, 61)) ^ (rs1 >> 6);
				6'd55: alu_result = {63'd0, xor_result == 64'd0};
				default: alu_result = 64'd0;
			endcase
			(* full_case, parallel_case *)
			case (operation_code)
				6'd7: word_result = word_sll_result;
				6'd9: word_result = word_srl_result;
				6'd8: word_result = word_sra_result;
				6'd39: word_result = word_rol_result;
				6'd40: word_result = word_ror_result;
				6'd36: word_result = clz_result[31:0];
				6'd37: word_result = ctz_result[31:0];
				6'd38: word_result = cpop_result[31:0];
				default: word_result = add_and_subtract_result[31:0];
			endcase
			alu = (is_word ? {{32 {word_result[31]}}, word_result} : alu_result);
		end
	endfunction
	wire ADDER_OPERATION;
	assign ADDER_OPERATION = ((((ALUop == 6'd0) || (ALUop == 6'd1)) || (ALUop == 6'd12)) || (ALUop == 6'd5)) || (ALUop == 6'd6);
	wire ADDER_SLT;
	wire ADDER_SLTU;
	assign ADDER_SLT = (A[63] != B[63] ? A[63] : ADDER_SUM[63]);
	assign ADDER_SLTU = ~ADDER_CARRY_OUT;
	reg [63:0] ADDER_FAMILY_RESULT;
	reg [63:0] OTHER_RESULT;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (ALUop)
			6'd5: ADDER_FAMILY_RESULT = {63'd0, ADDER_SLT};
			6'd6: ADDER_FAMILY_RESULT = {63'd0, ADDER_SLTU};
			default: ADDER_FAMILY_RESULT = (ALU_IS_WORD_OPERATION ? {{32 {ADDER_SUM[31]}}, ADDER_SUM[31:0]} : ADDER_SUM);
		endcase
		OTHER_RESULT = alu(A, B, ALUop, ALU_IS_WORD_OPERATION, 65'd0, CLZ_RESULT, CTZ_RESULT, 64'd0);
	end
	reg [63:0] LATE_VALUE;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (ALUop)
			6'd32: LATE_VALUE = (ADDER_SLT ? A : B);
			6'd33: LATE_VALUE = (ADDER_SLTU ? A : B);
			6'd34: LATE_VALUE = (ADDER_SLT ? B : A);
			6'd35: LATE_VALUE = (ADDER_SLTU ? B : A);
			default: LATE_VALUE = CPOP_RESULT;
		endcase
		ALUOutFast = (ADDER_OPERATION ? ADDER_FAMILY_RESULT : OTHER_RESULT);
		ALUOut = (LATE_RESULT ? LATE_VALUE : ALUOutFast);
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module MultiplyDivideUnit (
	A,
	B,
	MULTIPLY_DIVIDE_OPERATION,
	IS_WORD_OPERATION,
	MULTIPLY_DIVIDE_RESULT
);
	reg _sv2v_0;
	input wire [63:0] A;
	input wire [63:0] B;
	input wire [5:0] MULTIPLY_DIVIDE_OPERATION;
	input wire IS_WORD_OPERATION;
	output reg [63:0] MULTIPLY_DIVIDE_RESULT;
	wire A_IS_SIGNED;
	wire B_IS_SIGNED;
	wire [127:0] EXTENDED_A;
	wire [127:0] EXTENDED_B;
	wire [127:0] PRODUCT;
	assign A_IS_SIGNED = (MULTIPLY_DIVIDE_OPERATION == 6'd17) || (MULTIPLY_DIVIDE_OPERATION == 6'd18);
	assign B_IS_SIGNED = MULTIPLY_DIVIDE_OPERATION == 6'd17;
	assign EXTENDED_A = {{64 {A_IS_SIGNED & A[63]}}, A};
	assign EXTENDED_B = {{64 {B_IS_SIGNED & B[63]}}, B};
	assign PRODUCT = EXTENDED_A * EXTENDED_B;
	wire A_IS_NEGATIVE;
	wire B_IS_NEGATIVE;
	wire [63:0] A_MAGNITUDE;
	wire [63:0] B_MAGNITUDE;
	wire [63:0] QUOTIENT_MAGNITUDE;
	wire [63:0] REMAINDER_MAGNITUDE;
	wire DIVIDE_BY_ZERO;
	wire SIGNED_OVERFLOW;
	assign A_IS_NEGATIVE = A[63];
	assign B_IS_NEGATIVE = B[63];
	assign A_MAGNITUDE = (A_IS_NEGATIVE ? -A : A);
	assign B_MAGNITUDE = (B_IS_NEGATIVE ? -B : B);
	assign DIVIDE_BY_ZERO = B == 64'd0;
	assign SIGNED_OVERFLOW = (A == 64'h8000000000000000) && (B == 64'hffffffffffffffff);
	assign QUOTIENT_MAGNITUDE = (DIVIDE_BY_ZERO ? 64'd0 : A_MAGNITUDE / B_MAGNITUDE);
	assign REMAINDER_MAGNITUDE = (DIVIDE_BY_ZERO ? 64'd0 : A_MAGNITUDE % B_MAGNITUDE);
	wire [31:0] WORD_A;
	wire [31:0] WORD_B;
	wire WORD_A_IS_NEGATIVE;
	wire WORD_B_IS_NEGATIVE;
	wire [31:0] WORD_A_MAGNITUDE;
	wire [31:0] WORD_B_MAGNITUDE;
	wire [31:0] WORD_QUOTIENT_MAGNITUDE;
	wire [31:0] WORD_REMAINDER_MAGNITUDE;
	wire WORD_DIVIDE_BY_ZERO;
	wire WORD_SIGNED_OVERFLOW;
	assign WORD_A = A[31:0];
	assign WORD_B = B[31:0];
	assign WORD_A_IS_NEGATIVE = WORD_A[31];
	assign WORD_B_IS_NEGATIVE = WORD_B[31];
	assign WORD_A_MAGNITUDE = (WORD_A_IS_NEGATIVE ? -WORD_A : WORD_A);
	assign WORD_B_MAGNITUDE = (WORD_B_IS_NEGATIVE ? -WORD_B : WORD_B);
	assign WORD_DIVIDE_BY_ZERO = WORD_B == 32'd0;
	assign WORD_SIGNED_OVERFLOW = (WORD_A == 32'h80000000) && (WORD_B == 32'hffffffff);
	assign WORD_QUOTIENT_MAGNITUDE = (WORD_DIVIDE_BY_ZERO ? 32'd0 : WORD_A_MAGNITUDE / WORD_B_MAGNITUDE);
	assign WORD_REMAINDER_MAGNITUDE = (WORD_DIVIDE_BY_ZERO ? 32'd0 : WORD_A_MAGNITUDE % WORD_B_MAGNITUDE);
	reg [63:0] FULL_RESULT;
	reg [31:0] WORD_RESULT;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (MULTIPLY_DIVIDE_OPERATION)
			6'd16: FULL_RESULT = PRODUCT[63:0];
			6'd17, 6'd18, 6'd19: FULL_RESULT = PRODUCT[127:64];
			6'd20: FULL_RESULT = (DIVIDE_BY_ZERO ? 64'hffffffffffffffff : (SIGNED_OVERFLOW ? A : (A_IS_NEGATIVE ^ B_IS_NEGATIVE ? -QUOTIENT_MAGNITUDE : QUOTIENT_MAGNITUDE)));
			6'd21: FULL_RESULT = (DIVIDE_BY_ZERO ? 64'hffffffffffffffff : A / B);
			6'd22: FULL_RESULT = (DIVIDE_BY_ZERO ? A : (SIGNED_OVERFLOW ? 64'd0 : (A_IS_NEGATIVE ? -REMAINDER_MAGNITUDE : REMAINDER_MAGNITUDE)));
			6'd23: FULL_RESULT = (DIVIDE_BY_ZERO ? A : A % B);
			default: FULL_RESULT = 64'd0;
		endcase
		(* full_case, parallel_case *)
		case (MULTIPLY_DIVIDE_OPERATION)
			6'd16: WORD_RESULT = PRODUCT[31:0];
			6'd20: WORD_RESULT = (WORD_DIVIDE_BY_ZERO ? 32'hffffffff : (WORD_SIGNED_OVERFLOW ? WORD_A : (WORD_A_IS_NEGATIVE ^ WORD_B_IS_NEGATIVE ? -WORD_QUOTIENT_MAGNITUDE : WORD_QUOTIENT_MAGNITUDE)));
			6'd21: WORD_RESULT = (WORD_DIVIDE_BY_ZERO ? 32'hffffffff : WORD_A / WORD_B);
			6'd22: WORD_RESULT = (WORD_DIVIDE_BY_ZERO ? WORD_A : (WORD_SIGNED_OVERFLOW ? 32'd0 : (WORD_A_IS_NEGATIVE ? -WORD_REMAINDER_MAGNITUDE : WORD_REMAINDER_MAGNITUDE)));
			6'd23: WORD_RESULT = (WORD_DIVIDE_BY_ZERO ? WORD_A : WORD_A % WORD_B);
			default: WORD_RESULT = 32'd0;
		endcase
		MULTIPLY_DIVIDE_RESULT = (IS_WORD_OPERATION ? {{32 {WORD_RESULT[31]}}, WORD_RESULT} : FULL_RESULT);
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module CarrySaveMultiplyStep (
	MULTIPLICAND,
	MULTIPLIER,
	ACCUMULATOR_SUM,
	ACCUMULATOR_CARRY,
	SUM_VECTOR,
	CARRY_VECTOR
);
	parameter signed [31:0] A_WIDTH = 64;
	parameter signed [31:0] B_WIDTH = 16;
	parameter signed [31:0] WIDTH = 86;
	parameter signed [31:0] ACCUMULATOR_WIDTH = 70;
	input wire [A_WIDTH - 1:0] MULTIPLICAND;
	input wire [B_WIDTH - 1:0] MULTIPLIER;
	input wire [ACCUMULATOR_WIDTH - 1:0] ACCUMULATOR_SUM;
	input wire [ACCUMULATOR_WIDTH - 1:0] ACCUMULATOR_CARRY;
	output wire [WIDTH - 1:0] SUM_VECTOR;
	output wire [WIDTH - 1:0] CARRY_VECTOR;
	localparam signed [31:0] OPERANDS = B_WIDTH + 2;
	function automatic signed [31:0] count_after;
		input reg signed [31:0] level;
		reg signed [31:0] n;
		begin
			n = OPERANDS;
			begin : sv2v_autoblock_1
				reg signed [31:0] i;
				for (i = 0; i < level; i = i + 1)
					n = (2 * (n / 3)) + (n % 3);
			end
			count_after = n;
		end
	endfunction
	function automatic signed [31:0] levels_needed;
		input reg _sv2v_unused;
		reg signed [31:0] n;
		reg signed [31:0] levels;
		begin
			n = OPERANDS;
			levels = 0;
			while (n > 2) begin
				n = (2 * (n / 3)) + (n % 3);
				levels = levels + 1;
			end
			levels_needed = levels;
		end
	endfunction
	localparam signed [31:0] LEVELS = levels_needed(0);
	genvar _gv_LEVEL_4;
	genvar _gv_ROW_1;
	generate
		for (_gv_LEVEL_4 = 0; _gv_LEVEL_4 <= LEVELS; _gv_LEVEL_4 = _gv_LEVEL_4 + 1) begin : level
			localparam LEVEL = _gv_LEVEL_4;
			localparam signed [31:0] COUNT = count_after(LEVEL);
			wire [WIDTH - 1:0] OPERAND [0:COUNT - 1];
			if (LEVEL == 0) begin : partial_products
				for (_gv_ROW_1 = 0; _gv_ROW_1 < B_WIDTH; _gv_ROW_1 = _gv_ROW_1 + 1) begin : row
					localparam ROW = _gv_ROW_1;
					assign OPERAND[ROW] = (MULTIPLIER[ROW] ? {{WIDTH - A_WIDTH {1'b0}}, MULTIPLICAND} << ROW : {WIDTH {1'sb0}});
				end
				assign OPERAND[B_WIDTH] = {{WIDTH - ACCUMULATOR_WIDTH {1'b0}}, ACCUMULATOR_SUM};
				assign OPERAND[B_WIDTH + 1] = {{WIDTH - ACCUMULATOR_WIDTH {1'b0}}, ACCUMULATOR_CARRY};
			end
			else begin : compress
				localparam signed [31:0] PREVIOUS = count_after(LEVEL - 1);
				for (_gv_ROW_1 = 0; _gv_ROW_1 < (PREVIOUS / 3); _gv_ROW_1 = _gv_ROW_1 + 1) begin : full_adders
					localparam ROW = _gv_ROW_1;
					wire [WIDTH - 1:0] X;
					wire [WIDTH - 1:0] Y;
					wire [WIDTH - 1:0] Z;
					assign X = level[LEVEL - 1].OPERAND[3 * ROW];
					assign Y = level[LEVEL - 1].OPERAND[(3 * ROW) + 1];
					assign Z = level[LEVEL - 1].OPERAND[(3 * ROW) + 2];
					assign OPERAND[2 * ROW] = (X ^ Y) ^ Z;
					assign OPERAND[(2 * ROW) + 1] = {((X[WIDTH - 2:0] & Y[WIDTH - 2:0]) | (X[WIDTH - 2:0] & Z[WIDTH - 2:0])) | (Y[WIDTH - 2:0] & Z[WIDTH - 2:0]), 1'b0};
				end
				for (_gv_ROW_1 = 0; _gv_ROW_1 < (PREVIOUS % 3); _gv_ROW_1 = _gv_ROW_1 + 1) begin : pass_through
					localparam ROW = _gv_ROW_1;
					assign OPERAND[(2 * (PREVIOUS / 3)) + ROW] = level[LEVEL - 1].OPERAND[(3 * (PREVIOUS / 3)) + ROW];
				end
			end
		end
	endgenerate
	assign SUM_VECTOR = level[LEVELS].OPERAND[0];
	assign CARRY_VECTOR = level[LEVELS].OPERAND[1];
endmodule
`default_nettype wire
`default_nettype none
module IterativeMultiplyDivideUnit (
	clk,
	reset,
	FREEZE,
	REQUEST,
	A,
	B,
	MULTIPLY_DIVIDE_OPERATION,
	IS_WORD_OPERATION,
	PREDECODED,
	READY,
	MULTIPLY_DIVIDE_RESULT
);
	reg _sv2v_0;
	input wire clk;
	input wire reset;
	input wire FREEZE;
	input wire REQUEST;
	input wire [63:0] A;
	input wire [63:0] B;
	input wire [5:0] MULTIPLY_DIVIDE_OPERATION;
	input wire IS_WORD_OPERATION;
	input wire [2:0] PREDECODED;
	output wire READY;
	output wire [63:0] MULTIPLY_DIVIDE_RESULT;
	reg [2:0] UNIT_STATE;
	wire IS_DIVIDE;
	wire IS_REMAINDER;
	wire A_IS_SIGNED;
	wire B_IS_SIGNED;
	assign IS_DIVIDE = (((MULTIPLY_DIVIDE_OPERATION == 6'd20) || (MULTIPLY_DIVIDE_OPERATION == 6'd21)) || (MULTIPLY_DIVIDE_OPERATION == 6'd22)) || (MULTIPLY_DIVIDE_OPERATION == 6'd23);
	assign IS_REMAINDER = (MULTIPLY_DIVIDE_OPERATION == 6'd22) || (MULTIPLY_DIVIDE_OPERATION == 6'd23);
	assign A_IS_SIGNED = PREDECODED[2];
	assign B_IS_SIGNED = PREDECODED[1];
	wire [63:0] A_EFFECTIVE;
	wire [63:0] B_EFFECTIVE;
	assign A_EFFECTIVE = (PREDECODED[0] ? (A_IS_SIGNED ? {{32 {A[31]}}, A[31:0]} : {32'd0, A[31:0]}) : A);
	assign B_EFFECTIVE = (PREDECODED[0] ? (B_IS_SIGNED ? {{32 {B[31]}}, B[31:0]} : {32'd0, B[31:0]}) : B);
	wire A_IS_NEGATIVE;
	wire B_IS_NEGATIVE;
	assign A_IS_NEGATIVE = A_IS_SIGNED && A_EFFECTIVE[63];
	assign B_IS_NEGATIVE = B_IS_SIGNED && B_EFFECTIVE[63];
	reg [63:0] LATCHED_A;
	reg [63:0] LATCHED_B;
	reg LATCHED_A_IS_NEGATIVE;
	reg LATCHED_B_IS_NEGATIVE;
	wire [63:0] A_MAGNITUDE;
	wire [63:0] B_MAGNITUDE;
	wire [63:0] A_NEGATED;
	wire [63:0] B_NEGATED;
	PrefixNegate #(.WIDTH(64)) negate_a(
		.X(A_EFFECTIVE),
		.NEGATED(A_NEGATED)
	);
	PrefixNegate #(.WIDTH(64)) negate_b(
		.X(B_EFFECTIVE),
		.NEGATED(B_NEGATED)
	);
	assign A_MAGNITUDE = LATCHED_A;
	assign B_MAGNITUDE = LATCHED_B;
	wire [6:0] DIVIDE_STEPS;
	reg [63:0] ALIGNED_DIVIDEND;
	wire [5:0] LEADING_ZEROS;
	wire DIVIDEND_IS_ZERO_UNUSED;
	LeadingZeroCounter count_dividend_zeros(
		.X(A_MAGNITUDE),
		.COUNT(LEADING_ZEROS),
		.ALL_ZERO(DIVIDEND_IS_ZERO_UNUSED)
	);
	reg [5:0] LATCHED_LEADING_ZEROS;
	assign DIVIDE_STEPS = 7'd64 - {1'b0, LATCHED_LEADING_ZEROS};
	always @(*) begin : sv2v_autoblock_1
		reg [63:0] NORMALIZED;
		if (_sv2v_0)
			;
		NORMALIZED = A_MAGNITUDE;
		if (LATCHED_LEADING_ZEROS[5])
			NORMALIZED = NORMALIZED << 32;
		if (LATCHED_LEADING_ZEROS[4])
			NORMALIZED = NORMALIZED << 16;
		if (LATCHED_LEADING_ZEROS[3])
			NORMALIZED = NORMALIZED << 8;
		if (LATCHED_LEADING_ZEROS[2])
			NORMALIZED = NORMALIZED << 4;
		if (LATCHED_LEADING_ZEROS[1])
			NORMALIZED = NORMALIZED << 2;
		if (LATCHED_LEADING_ZEROS[0])
			NORMALIZED = NORMALIZED << 1;
		ALIGNED_DIVIDEND = NORMALIZED;
	end
	reg [6:0] STEPS_LEFT;
	reg LATCHED_IS_DIVIDE;
	reg LATCHED_IS_REMAINDER;
	reg LATCHED_IS_WORD;
	reg LATCHED_NEGATE_PRODUCT;
	reg LATCHED_NEGATE_QUOTIENT;
	reg LATCHED_NEGATE_REMAINDER;
	reg LATCHED_DIVIDE_BY_ZERO;
	reg [5:0] LATCHED_OPERATION;
	reg [63:0] MULTIPLICAND;
	reg [133:0] PRODUCT_SUM;
	reg [133:0] PRODUCT_CARRY;
	reg [63:0] DIVISOR;
	reg [63:0] DIVIDEND_BITS;
	reg [63:0] PARTIAL_REMAINDER;
	reg [63:0] QUOTIENT;
	reg [63:0] RESULT_REGISTER;
	wire [85:0] MULTIPLY_STEP_SUM;
	wire [85:0] MULTIPLY_STEP_CARRY;
	CarrySaveMultiplyStep #(
		.A_WIDTH(64),
		.B_WIDTH(16),
		.WIDTH(86),
		.ACCUMULATOR_WIDTH(70)
	) multiply_step(
		.MULTIPLICAND(MULTIPLICAND),
		.MULTIPLIER(PRODUCT_SUM[15:0]),
		.ACCUMULATOR_SUM(PRODUCT_SUM[133:64]),
		.ACCUMULATOR_CARRY(PRODUCT_CARRY[133:64]),
		.SUM_VECTOR(MULTIPLY_STEP_SUM),
		.CARRY_VECTOR(MULTIPLY_STEP_CARRY)
	);
	wire [64:0] SHIFTED_REMAINDER;
	wire [64:0] TRIAL_DIFFERENCE;
	wire TRIAL_NO_BORROW;
	assign SHIFTED_REMAINDER = {PARTIAL_REMAINDER, DIVIDEND_BITS[63]};
	ParallelPrefixAdder #(.WIDTH(65)) divide_subtractor(
		.A(SHIFTED_REMAINDER),
		.B(~{1'b0, DIVISOR}),
		.CARRY_IN(1'b1),
		.SUM(TRIAL_DIFFERENCE),
		.CARRY_OUT(TRIAL_NO_BORROW)
	);
	reg [63:0] FINISHED_RESULT;
	always @(posedge clk)
		if (reset) begin
			UNIT_STATE <= 3'd0;
			STEPS_LEFT <= 7'd0;
			RESULT_REGISTER <= 64'd0;
			LATCHED_LEADING_ZEROS <= 6'd0;
		end
		else if (!FREEZE)
			(* full_case, parallel_case *)
			case (UNIT_STATE)
				3'd0:
					if (REQUEST) begin
						UNIT_STATE <= 3'd3;
						LATCHED_A <= (A_IS_NEGATIVE ? A_NEGATED : A_EFFECTIVE);
						LATCHED_B <= (B_IS_NEGATIVE ? B_NEGATED : B_EFFECTIVE);
						LATCHED_A_IS_NEGATIVE <= A_IS_NEGATIVE;
						LATCHED_B_IS_NEGATIVE <= B_IS_NEGATIVE;
						LATCHED_OPERATION <= MULTIPLY_DIVIDE_OPERATION;
						LATCHED_IS_DIVIDE <= IS_DIVIDE;
						LATCHED_IS_REMAINDER <= IS_REMAINDER;
						LATCHED_IS_WORD <= IS_WORD_OPERATION;
						LATCHED_NEGATE_PRODUCT <= A_IS_NEGATIVE ^ B_IS_NEGATIVE;
						LATCHED_NEGATE_QUOTIENT <= A_IS_NEGATIVE ^ B_IS_NEGATIVE;
						LATCHED_NEGATE_REMAINDER <= A_IS_NEGATIVE;
						LATCHED_DIVIDE_BY_ZERO <= B_EFFECTIVE == 64'd0;
					end
				3'd3: begin
					UNIT_STATE <= (LATCHED_IS_DIVIDE ? 3'd5 : 3'd1);
					LATCHED_LEADING_ZEROS <= LEADING_ZEROS;
					MULTIPLICAND <= A_MAGNITUDE;
					PRODUCT_SUM <= {70'd0, B_MAGNITUDE};
					PRODUCT_CARRY <= 134'd0;
					DIVISOR <= B_MAGNITUDE;
					PARTIAL_REMAINDER <= 64'd0;
					QUOTIENT <= 64'd0;
					STEPS_LEFT <= 7'd4;
				end
				3'd5: begin
					UNIT_STATE <= 3'd1;
					DIVIDEND_BITS <= ALIGNED_DIVIDEND;
					STEPS_LEFT <= DIVIDE_STEPS;
				end
				3'd1: begin
					if (LATCHED_IS_DIVIDE) begin
						PARTIAL_REMAINDER <= (TRIAL_NO_BORROW ? TRIAL_DIFFERENCE[63:0] : SHIFTED_REMAINDER[63:0]);
						QUOTIENT <= {QUOTIENT[62:0], TRIAL_NO_BORROW};
						DIVIDEND_BITS <= {DIVIDEND_BITS[62:0], 1'b0};
					end
					else begin
						PRODUCT_SUM <= {MULTIPLY_STEP_SUM, PRODUCT_SUM[63:16]};
						PRODUCT_CARRY <= {MULTIPLY_STEP_CARRY, PRODUCT_CARRY[63:16]};
					end
					STEPS_LEFT <= STEPS_LEFT - 7'd1;
					if (STEPS_LEFT == 7'd1)
						UNIT_STATE <= 3'd4;
				end
				3'd4: begin
					RESULT_REGISTER <= FINISHED_RESULT;
					UNIT_STATE <= 3'd2;
				end
				3'd2: UNIT_STATE <= 3'd0;
				default: UNIT_STATE <= 3'd0;
			endcase
	wire [127:0] SIGNED_PRODUCT;
	wire [63:0] SIGNED_QUOTIENT;
	wire [63:0] SIGNED_REMAINDER;
	reg [63:0] FULL_RESULT;
	wire [63:0] QUOTIENT_NEGATED;
	wire [63:0] REMAINDER_NEGATED;
	wire [127:0] PRODUCT_X;
	wire [127:0] PRODUCT_Y;
	wire [127:0] PRODUCT_Z;
	wire [127:0] RESOLVE_SUM_BITS;
	wire [127:0] RESOLVE_CARRY_BITS;
	wire [127:0] RESOLVED_PRODUCT;
	wire RESOLVE_CARRY_UNUSED;
	assign PRODUCT_X = PRODUCT_SUM[127:0];
	assign PRODUCT_Y = PRODUCT_CARRY[127:0];
	assign PRODUCT_Z = {128 {LATCHED_NEGATE_PRODUCT}};
	assign RESOLVE_SUM_BITS = (PRODUCT_X ^ PRODUCT_Y) ^ PRODUCT_Z;
	assign RESOLVE_CARRY_BITS = {((PRODUCT_X[126:0] & PRODUCT_Y[126:0]) | (PRODUCT_X[126:0] & PRODUCT_Z[126:0])) | (PRODUCT_Y[126:0] & PRODUCT_Z[126:0]), 1'b0};
	ParallelPrefixAdder #(.WIDTH(128)) resolve_product(
		.A(RESOLVE_SUM_BITS),
		.B(RESOLVE_CARRY_BITS),
		.CARRY_IN(1'b0),
		.SUM(RESOLVED_PRODUCT),
		.CARRY_OUT(RESOLVE_CARRY_UNUSED)
	);
	PrefixNegate #(.WIDTH(64)) negate_quotient(
		.X(QUOTIENT),
		.NEGATED(QUOTIENT_NEGATED)
	);
	PrefixNegate #(.WIDTH(64)) negate_remainder(
		.X(PARTIAL_REMAINDER),
		.NEGATED(REMAINDER_NEGATED)
	);
	assign SIGNED_PRODUCT = RESOLVED_PRODUCT ^ PRODUCT_Z;
	assign SIGNED_QUOTIENT = (LATCHED_NEGATE_QUOTIENT ? QUOTIENT_NEGATED : QUOTIENT);
	assign SIGNED_REMAINDER = (LATCHED_NEGATE_REMAINDER ? REMAINDER_NEGATED : PARTIAL_REMAINDER);
	always @(*) begin
		if (_sv2v_0)
			;
		if (LATCHED_IS_DIVIDE) begin
			if (LATCHED_IS_REMAINDER)
				FULL_RESULT = SIGNED_REMAINDER;
			else
				FULL_RESULT = (LATCHED_DIVIDE_BY_ZERO ? 64'hffffffffffffffff : SIGNED_QUOTIENT);
		end
		else
			(* full_case, parallel_case *)
			case (LATCHED_OPERATION)
				6'd17, 6'd18, 6'd19: FULL_RESULT = SIGNED_PRODUCT[127:64];
				default: FULL_RESULT = SIGNED_PRODUCT[63:0];
			endcase
		FINISHED_RESULT = (LATCHED_IS_WORD ? {{32 {FULL_RESULT[31]}}, FULL_RESULT[31:0]} : FULL_RESULT);
	end
	assign MULTIPLY_DIVIDE_RESULT = RESULT_REGISTER;
	assign READY = UNIT_STATE == 3'd2;
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module ALUdec (
	opcode,
	funct,
	funct7,
	funct12,
	ALUop,
	OPERAND_A_ZERO_EXTEND,
	OPERAND_A_SHIFT,
	OPERAND_B_INVERT,
	OPERAND_B_SINGLE_BIT,
	FULL_WIDTH_RESULT
);
	reg _sv2v_0;
	input wire [6:0] opcode;
	input wire [2:0] funct;
	input wire [6:0] funct7;
	input wire [11:0] funct12;
	output reg [5:0] ALUop;
	output reg OPERAND_A_ZERO_EXTEND;
	output reg [1:0] OPERAND_A_SHIFT;
	output reg OPERAND_B_INVERT;
	output reg OPERAND_B_SINGLE_BIT;
	output reg FULL_WIDTH_RESULT;
	wire [5:0] funct6;
	wire sra_type;
	assign funct6 = funct7[6:1];
	assign sra_type = funct7[5];
	reg [5:0] base_operation;
	localparam [2:0] opcode_pkg_FNC_ADD_SUB = 3'b000;
	localparam [2:0] opcode_pkg_FNC_AND = 3'b111;
	localparam [2:0] opcode_pkg_FNC_OR = 3'b110;
	localparam [2:0] opcode_pkg_FNC_SLL = 3'b001;
	localparam [2:0] opcode_pkg_FNC_SLT = 3'b010;
	localparam [2:0] opcode_pkg_FNC_SLTU = 3'b011;
	localparam [2:0] opcode_pkg_FNC_SRL_SRA = 3'b101;
	localparam [2:0] opcode_pkg_FNC_XOR = 3'b100;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (funct)
			opcode_pkg_FNC_ADD_SUB: base_operation = 6'd0;
			opcode_pkg_FNC_SLL: base_operation = 6'd7;
			opcode_pkg_FNC_SLT: base_operation = 6'd5;
			opcode_pkg_FNC_SLTU: base_operation = 6'd6;
			opcode_pkg_FNC_XOR: base_operation = 6'd4;
			opcode_pkg_FNC_SRL_SRA:
				if (sra_type)
					base_operation = 6'd8;
				else
					base_operation = 6'd9;
			opcode_pkg_FNC_OR: base_operation = 6'd3;
			opcode_pkg_FNC_AND: base_operation = 6'd2;
			default: base_operation = 6'd63;
		endcase
	end
	localparam [6:0] opcode_pkg_FNC7_MULTIPLY_DIVIDE = 7'b0000001;
	localparam [2:0] opcode_pkg_FNC_DIV = 3'b100;
	localparam [2:0] opcode_pkg_FNC_DIVU = 3'b101;
	localparam [2:0] opcode_pkg_FNC_MUL = 3'b000;
	localparam [2:0] opcode_pkg_FNC_MULH = 3'b001;
	localparam [2:0] opcode_pkg_FNC_MULHSU = 3'b010;
	localparam [2:0] opcode_pkg_FNC_MULHU = 3'b011;
	localparam [2:0] opcode_pkg_FNC_REM = 3'b110;
	localparam [2:0] opcode_pkg_FNC_REMU = 3'b111;
	localparam [2:0] opcode_pkg_FNC_RW = 3'b001;
	localparam [2:0] opcode_pkg_FNC_RWI = 3'b101;
	localparam [6:0] opcode_pkg_OPC_ARI_ITYPE = 7'b0010011;
	localparam [6:0] opcode_pkg_OPC_ARI_ITYPE_WORD = 7'b0011011;
	localparam [6:0] opcode_pkg_OPC_ARI_RTYPE = 7'b0110011;
	localparam [6:0] opcode_pkg_OPC_ARI_RTYPE_WORD = 7'b0111011;
	localparam [6:0] opcode_pkg_OPC_AUIPC = 7'b0010111;
	localparam [6:0] opcode_pkg_OPC_BRANCH = 7'b1100011;
	localparam [6:0] opcode_pkg_OPC_CSR = 7'b1110011;
	localparam [6:0] opcode_pkg_OPC_CUSTOM0 = 7'b0001011;
	localparam [6:0] opcode_pkg_OPC_JAL = 7'b1101111;
	localparam [6:0] opcode_pkg_OPC_JALR = 7'b1100111;
	localparam [6:0] opcode_pkg_OPC_LOAD = 7'b0000011;
	localparam [6:0] opcode_pkg_OPC_LUI = 7'b0110111;
	localparam [6:0] opcode_pkg_OPC_STORE = 7'b0100011;
	always @(*) begin
		if (_sv2v_0)
			;
		ALUop = 6'd63;
		OPERAND_A_ZERO_EXTEND = 1'b0;
		OPERAND_A_SHIFT = 2'd0;
		OPERAND_B_INVERT = 1'b0;
		OPERAND_B_SINGLE_BIT = 1'b0;
		FULL_WIDTH_RESULT = 1'b0;
		(* full_case, parallel_case *)
		case (opcode)
			opcode_pkg_OPC_LUI: ALUop = 6'd10;
			opcode_pkg_OPC_AUIPC: ALUop = 6'd0;
			opcode_pkg_OPC_JAL: ALUop = 6'd0;
			opcode_pkg_OPC_JALR: ALUop = 6'd12;
			opcode_pkg_OPC_BRANCH: ALUop = 6'd0;
			opcode_pkg_OPC_LOAD: ALUop = 6'd0;
			opcode_pkg_OPC_STORE: ALUop = 6'd0;
			opcode_pkg_OPC_ARI_ITYPE:
				if (funct == opcode_pkg_FNC_SLL)
					(* full_case, parallel_case *)
					case (funct12)
						12'h600: ALUop = 6'd36;
						12'h601: ALUop = 6'd37;
						12'h602: ALUop = 6'd38;
						12'h604: ALUop = 6'd41;
						12'h605: ALUop = 6'd42;
						12'h100: ALUop = 6'd47;
						12'h101: ALUop = 6'd48;
						12'h102: ALUop = 6'd49;
						12'h103: ALUop = 6'd50;
						12'h104: ALUop = 6'd51;
						12'h105: ALUop = 6'd52;
						12'h106: ALUop = 6'd53;
						12'h107: ALUop = 6'd54;
						default:
							(* full_case, parallel_case *)
							case (funct6)
								6'b001010: begin
									ALUop = 6'd3;
									OPERAND_B_SINGLE_BIT = 1'b1;
								end
								6'b010010: begin
									ALUop = 6'd2;
									OPERAND_B_SINGLE_BIT = 1'b1;
									OPERAND_B_INVERT = 1'b1;
								end
								6'b011010: begin
									ALUop = 6'd4;
									OPERAND_B_SINGLE_BIT = 1'b1;
								end
								default: ALUop = 6'd7;
							endcase
					endcase
				else if (funct == opcode_pkg_FNC_SRL_SRA) begin
					if (funct12 == 12'h6b8)
						ALUop = 6'd44;
					else if (funct12 == 12'h287)
						ALUop = 6'd45;
					else if (funct6 == 6'b011000)
						ALUop = 6'd40;
					else if (funct6 == 6'b010010)
						ALUop = 6'd46;
					else
						ALUop = base_operation;
				end
				else
					ALUop = base_operation;
			opcode_pkg_OPC_ARI_ITYPE_WORD:
				if (funct == opcode_pkg_FNC_SLL)
					(* full_case, parallel_case *)
					case (funct12)
						12'h600: ALUop = 6'd36;
						12'h601: ALUop = 6'd37;
						12'h602: ALUop = 6'd38;
						default: begin
							ALUop = 6'd7;
							if (funct6 == 6'b000010) begin
								OPERAND_A_ZERO_EXTEND = 1'b1;
								FULL_WIDTH_RESULT = 1'b1;
							end
						end
					endcase
				else if (funct == opcode_pkg_FNC_SRL_SRA) begin
					if (funct7 == 7'b0110000)
						ALUop = 6'd40;
					else
						ALUop = base_operation;
				end
				else
					ALUop = base_operation;
			opcode_pkg_OPC_ARI_RTYPE, opcode_pkg_OPC_ARI_RTYPE_WORD:
				(* full_case, parallel_case *)
				case (funct7)
					opcode_pkg_FNC7_MULTIPLY_DIVIDE:
						(* full_case, parallel_case *)
						case (funct)
							opcode_pkg_FNC_MUL: ALUop = 6'd16;
							opcode_pkg_FNC_MULH: ALUop = 6'd17;
							opcode_pkg_FNC_MULHSU: ALUop = 6'd18;
							opcode_pkg_FNC_MULHU: ALUop = 6'd19;
							opcode_pkg_FNC_DIV: ALUop = 6'd20;
							opcode_pkg_FNC_DIVU: ALUop = 6'd21;
							opcode_pkg_FNC_REM: ALUop = 6'd22;
							opcode_pkg_FNC_REMU: ALUop = 6'd23;
							default: ALUop = 6'd63;
						endcase
					7'b0000000: ALUop = base_operation;
					7'b0100000:
						if (funct == opcode_pkg_FNC_ADD_SUB)
							ALUop = 6'd1;
						else if (funct == opcode_pkg_FNC_SRL_SRA)
							ALUop = 6'd8;
						else if ((opcode == opcode_pkg_OPC_ARI_RTYPE) && (((funct == opcode_pkg_FNC_AND) || (funct == opcode_pkg_FNC_OR)) || (funct == opcode_pkg_FNC_XOR))) begin
							ALUop = base_operation;
							OPERAND_B_INVERT = 1'b1;
						end
					7'b0010000:
						if (((funct == 3'b010) || (funct == 3'b100)) || (funct == 3'b110)) begin
							ALUop = 6'd0;
							OPERAND_A_SHIFT = funct[2:1];
							OPERAND_A_ZERO_EXTEND = opcode == opcode_pkg_OPC_ARI_RTYPE_WORD;
							FULL_WIDTH_RESULT = opcode == opcode_pkg_OPC_ARI_RTYPE_WORD;
						end
					7'b0000101:
						if (opcode == opcode_pkg_OPC_ARI_RTYPE)
							(* full_case, parallel_case *)
							case (funct)
								3'b100: ALUop = 6'd32;
								3'b101: ALUop = 6'd33;
								3'b110: ALUop = 6'd34;
								3'b111: ALUop = 6'd35;
								default: ALUop = 6'd63;
							endcase
					7'b0110000:
						if (funct == opcode_pkg_FNC_SLL)
							ALUop = 6'd39;
						else if (funct == opcode_pkg_FNC_SRL_SRA)
							ALUop = 6'd40;
					7'b0010100:
						if ((opcode == opcode_pkg_OPC_ARI_RTYPE) && (funct == opcode_pkg_FNC_SLL)) begin
							ALUop = 6'd3;
							OPERAND_B_SINGLE_BIT = 1'b1;
						end
					7'b0100100:
						if ((opcode == opcode_pkg_OPC_ARI_RTYPE) && (funct == opcode_pkg_FNC_SLL)) begin
							ALUop = 6'd2;
							OPERAND_B_SINGLE_BIT = 1'b1;
							OPERAND_B_INVERT = 1'b1;
						end
						else if ((opcode == opcode_pkg_OPC_ARI_RTYPE) && (funct == opcode_pkg_FNC_SRL_SRA))
							ALUop = 6'd46;
					7'b0110100:
						if ((opcode == opcode_pkg_OPC_ARI_RTYPE) && (funct == opcode_pkg_FNC_SLL)) begin
							ALUop = 6'd4;
							OPERAND_B_SINGLE_BIT = 1'b1;
						end
					7'b0000100:
						if ((opcode == opcode_pkg_OPC_ARI_RTYPE_WORD) && (funct == opcode_pkg_FNC_ADD_SUB)) begin
							ALUop = 6'd0;
							OPERAND_A_ZERO_EXTEND = 1'b1;
							FULL_WIDTH_RESULT = 1'b1;
						end
						else if ((opcode == opcode_pkg_OPC_ARI_RTYPE_WORD) && (funct == opcode_pkg_FNC_XOR)) begin
							ALUop = 6'd43;
							FULL_WIDTH_RESULT = 1'b1;
						end
					default: ALUop = 6'd63;
				endcase
			opcode_pkg_OPC_CSR:
				(* full_case, parallel_case *)
				case (funct)
					opcode_pkg_FNC_RW: ALUop = 6'd10;
					opcode_pkg_FNC_RWI: ALUop = 6'd10;
					default: ALUop = 6'd63;
				endcase
			opcode_pkg_OPC_CUSTOM0:
				if ((funct7 == 7'b0000000) && (funct == 3'b110))
					ALUop = 6'd55;
			default: ALUop = 6'd63;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module ControlUnit (
	INSTRUCTION,
	REGISTER_WRITE_ENABLE,
	MEMORY_READ_ENABLE,
	MEMORY_WRITE_ENABLE,
	CSR_WRITE_ENABLE,
	CSR_WRITE_USING_IMMEDIATE,
	ALU_INPUT_A_IS_PC,
	ALU_INPUT_B_IS_IMMEDIATE,
	ALU_IS_WORD_OPERATION,
	IS_A_MULTIPLY_DIVIDE_INSTRUCTION,
	IS_A_BRANCH_INSTRUCTION,
	IS_A_JAL_INSTRUCTION,
	IS_A_JALR_INSTRUCTION,
	IS_AN_ECALL,
	IS_AN_EBREAK,
	IS_AN_MRET,
	USES_REGISTER1,
	USES_REGISTER2,
	IMMEDIATE_TYPE_SELECT,
	WRITEBACK_SELECT,
	ALU_OPERATION,
	ALU_OPERAND_A_ZERO_EXTEND,
	ALU_OPERAND_A_SHIFT,
	ALU_OPERAND_B_INVERT,
	ALU_OPERAND_B_SINGLE_BIT
);
	reg _sv2v_0;
	input wire [31:0] INSTRUCTION;
	output reg REGISTER_WRITE_ENABLE;
	output reg MEMORY_READ_ENABLE;
	output reg MEMORY_WRITE_ENABLE;
	output reg CSR_WRITE_ENABLE;
	output reg CSR_WRITE_USING_IMMEDIATE;
	output reg ALU_INPUT_A_IS_PC;
	output reg ALU_INPUT_B_IS_IMMEDIATE;
	output reg ALU_IS_WORD_OPERATION;
	output reg IS_A_MULTIPLY_DIVIDE_INSTRUCTION;
	output reg IS_A_BRANCH_INSTRUCTION;
	output reg IS_A_JAL_INSTRUCTION;
	output reg IS_A_JALR_INSTRUCTION;
	output wire IS_AN_ECALL;
	output wire IS_AN_EBREAK;
	output wire IS_AN_MRET;
	output reg USES_REGISTER1;
	output reg USES_REGISTER2;
	output reg [2:0] IMMEDIATE_TYPE_SELECT;
	output reg [1:0] WRITEBACK_SELECT;
	output wire [5:0] ALU_OPERATION;
	output wire ALU_OPERAND_A_ZERO_EXTEND;
	output wire [1:0] ALU_OPERAND_A_SHIFT;
	output wire ALU_OPERAND_B_INVERT;
	output wire ALU_OPERAND_B_SINGLE_BIT;
	wire [6:0] INSTRUCTION_OPCODE;
	wire [2:0] INSTRUCTION_FUNCT3;
	wire [6:0] INSTRUCTION_FUNCT7;
	wire [4:0] INSTRUCTION_REGISTER1_FIELD;
	wire INSTRUCTION_MULTIPLY_DIVIDE_TYPE;
	assign INSTRUCTION_OPCODE = INSTRUCTION[6:0];
	assign INSTRUCTION_FUNCT3 = INSTRUCTION[14:12];
	assign INSTRUCTION_FUNCT7 = INSTRUCTION[31:25];
	assign INSTRUCTION_REGISTER1_FIELD = INSTRUCTION[19:15];
	localparam [6:0] opcode_pkg_FNC7_MULTIPLY_DIVIDE = 7'b0000001;
	assign INSTRUCTION_MULTIPLY_DIVIDE_TYPE = INSTRUCTION_FUNCT7 == opcode_pkg_FNC7_MULTIPLY_DIVIDE;
	wire FULL_WIDTH_RESULT;
	ALUdec alu_decode(
		.opcode(INSTRUCTION_OPCODE),
		.funct(INSTRUCTION_FUNCT3),
		.funct7(INSTRUCTION_FUNCT7),
		.funct12(INSTRUCTION[31:20]),
		.ALUop(ALU_OPERATION),
		.OPERAND_A_ZERO_EXTEND(ALU_OPERAND_A_ZERO_EXTEND),
		.OPERAND_A_SHIFT(ALU_OPERAND_A_SHIFT),
		.OPERAND_B_INVERT(ALU_OPERAND_B_INVERT),
		.OPERAND_B_SINGLE_BIT(ALU_OPERAND_B_SINGLE_BIT),
		.FULL_WIDTH_RESULT(FULL_WIDTH_RESULT)
	);
	wire IS_A_PRIVILEGED_SYSTEM_INSTRUCTION;
	localparam [2:0] opcode_pkg_FNC_PRIV = 3'b000;
	localparam [6:0] opcode_pkg_OPC_CSR = 7'b1110011;
	assign IS_A_PRIVILEGED_SYSTEM_INSTRUCTION = (((INSTRUCTION_OPCODE == opcode_pkg_OPC_CSR) && (INSTRUCTION_FUNCT3 == opcode_pkg_FNC_PRIV)) && (INSTRUCTION[19:15] == 5'd0)) && (INSTRUCTION[11:7] == 5'd0);
	assign IS_AN_ECALL = IS_A_PRIVILEGED_SYSTEM_INSTRUCTION && (INSTRUCTION[31:20] == 12'h000);
	assign IS_AN_EBREAK = IS_A_PRIVILEGED_SYSTEM_INSTRUCTION && (INSTRUCTION[31:20] == 12'h001);
	assign IS_AN_MRET = IS_A_PRIVILEGED_SYSTEM_INSTRUCTION && (INSTRUCTION[31:20] == 12'h302);
	localparam [2:0] opcode_pkg_FNC_RC = 3'b011;
	localparam [2:0] opcode_pkg_FNC_RS = 3'b010;
	localparam [2:0] opcode_pkg_FNC_RW = 3'b001;
	localparam [6:0] opcode_pkg_OPC_ARI_ITYPE = 7'b0010011;
	localparam [6:0] opcode_pkg_OPC_ARI_ITYPE_WORD = 7'b0011011;
	localparam [6:0] opcode_pkg_OPC_ARI_RTYPE = 7'b0110011;
	localparam [6:0] opcode_pkg_OPC_ARI_RTYPE_WORD = 7'b0111011;
	localparam [6:0] opcode_pkg_OPC_BRANCH = 7'b1100011;
	localparam [6:0] opcode_pkg_OPC_CUSTOM0 = 7'b0001011;
	localparam [6:0] opcode_pkg_OPC_JALR = 7'b1100111;
	localparam [6:0] opcode_pkg_OPC_LOAD = 7'b0000011;
	localparam [6:0] opcode_pkg_OPC_STORE = 7'b0100011;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (INSTRUCTION_OPCODE)
			opcode_pkg_OPC_ARI_RTYPE, opcode_pkg_OPC_ARI_RTYPE_WORD, opcode_pkg_OPC_STORE, opcode_pkg_OPC_BRANCH, opcode_pkg_OPC_CUSTOM0: begin
				USES_REGISTER1 = 1'b1;
				USES_REGISTER2 = 1'b1;
			end
			opcode_pkg_OPC_ARI_ITYPE, opcode_pkg_OPC_ARI_ITYPE_WORD, opcode_pkg_OPC_LOAD, opcode_pkg_OPC_JALR: begin
				USES_REGISTER1 = 1'b1;
				USES_REGISTER2 = 1'b0;
			end
			opcode_pkg_OPC_CSR: begin
				USES_REGISTER1 = ((INSTRUCTION_FUNCT3 == opcode_pkg_FNC_RW) || (INSTRUCTION_FUNCT3 == opcode_pkg_FNC_RS)) || (INSTRUCTION_FUNCT3 == opcode_pkg_FNC_RC);
				USES_REGISTER2 = 1'b0;
			end
			default: begin
				USES_REGISTER1 = 1'b0;
				USES_REGISTER2 = 1'b0;
			end
		endcase
	end
	localparam [2:0] opcode_pkg_FNC_RCI = 3'b111;
	localparam [2:0] opcode_pkg_FNC_RSI = 3'b110;
	localparam [2:0] opcode_pkg_FNC_RWI = 3'b101;
	localparam [6:0] opcode_pkg_OPC_AUIPC = 7'b0010111;
	localparam [6:0] opcode_pkg_OPC_JAL = 7'b1101111;
	localparam [6:0] opcode_pkg_OPC_LUI = 7'b0110111;
	always @(*) begin
		if (_sv2v_0)
			;
		REGISTER_WRITE_ENABLE = 1'b0;
		MEMORY_READ_ENABLE = 1'b0;
		MEMORY_WRITE_ENABLE = 1'b0;
		CSR_WRITE_ENABLE = 1'b0;
		CSR_WRITE_USING_IMMEDIATE = 1'b0;
		ALU_INPUT_A_IS_PC = 1'b0;
		ALU_INPUT_B_IS_IMMEDIATE = 1'b0;
		ALU_IS_WORD_OPERATION = 1'b0;
		IS_A_MULTIPLY_DIVIDE_INSTRUCTION = 1'b0;
		IS_A_BRANCH_INSTRUCTION = 1'b0;
		IS_A_JAL_INSTRUCTION = 1'b0;
		IS_A_JALR_INSTRUCTION = 1'b0;
		IMMEDIATE_TYPE_SELECT = 3'd0;
		WRITEBACK_SELECT = 2'd0;
		(* full_case, parallel_case *)
		case (INSTRUCTION_OPCODE)
			opcode_pkg_OPC_LUI: begin
				REGISTER_WRITE_ENABLE = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				IMMEDIATE_TYPE_SELECT = 3'd3;
				WRITEBACK_SELECT = 2'd0;
			end
			opcode_pkg_OPC_AUIPC: begin
				REGISTER_WRITE_ENABLE = 1'b1;
				ALU_INPUT_A_IS_PC = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				IMMEDIATE_TYPE_SELECT = 3'd3;
				WRITEBACK_SELECT = 2'd0;
			end
			opcode_pkg_OPC_JAL: begin
				IS_A_JAL_INSTRUCTION = 1'b1;
				REGISTER_WRITE_ENABLE = 1'b1;
				ALU_INPUT_A_IS_PC = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				IMMEDIATE_TYPE_SELECT = 3'd4;
				WRITEBACK_SELECT = 2'd2;
			end
			opcode_pkg_OPC_JALR: begin
				IS_A_JALR_INSTRUCTION = 1'b1;
				REGISTER_WRITE_ENABLE = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				IMMEDIATE_TYPE_SELECT = 3'd0;
				WRITEBACK_SELECT = 2'd2;
			end
			opcode_pkg_OPC_BRANCH: begin
				IS_A_BRANCH_INSTRUCTION = 1'b1;
				ALU_INPUT_A_IS_PC = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				IMMEDIATE_TYPE_SELECT = 3'd2;
			end
			opcode_pkg_OPC_STORE: begin
				MEMORY_WRITE_ENABLE = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				IMMEDIATE_TYPE_SELECT = 3'd1;
			end
			opcode_pkg_OPC_LOAD: begin
				REGISTER_WRITE_ENABLE = 1'b1;
				MEMORY_READ_ENABLE = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				IMMEDIATE_TYPE_SELECT = 3'd0;
				WRITEBACK_SELECT = 2'd1;
			end
			opcode_pkg_OPC_ARI_RTYPE: begin
				REGISTER_WRITE_ENABLE = 1'b1;
				IS_A_MULTIPLY_DIVIDE_INSTRUCTION = INSTRUCTION_MULTIPLY_DIVIDE_TYPE;
				WRITEBACK_SELECT = 2'd0;
			end
			opcode_pkg_OPC_CUSTOM0: begin
				REGISTER_WRITE_ENABLE = (INSTRUCTION_FUNCT7 == 7'b0000000) && (INSTRUCTION_FUNCT3 == 3'b110);
				WRITEBACK_SELECT = 2'd0;
			end
			opcode_pkg_OPC_ARI_ITYPE: begin
				REGISTER_WRITE_ENABLE = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				IMMEDIATE_TYPE_SELECT = 3'd0;
				WRITEBACK_SELECT = 2'd0;
			end
			opcode_pkg_OPC_ARI_RTYPE_WORD: begin
				REGISTER_WRITE_ENABLE = 1'b1;
				ALU_IS_WORD_OPERATION = !FULL_WIDTH_RESULT;
				IS_A_MULTIPLY_DIVIDE_INSTRUCTION = INSTRUCTION_MULTIPLY_DIVIDE_TYPE;
				WRITEBACK_SELECT = 2'd0;
			end
			opcode_pkg_OPC_ARI_ITYPE_WORD: begin
				REGISTER_WRITE_ENABLE = 1'b1;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b1;
				ALU_IS_WORD_OPERATION = !FULL_WIDTH_RESULT;
				IMMEDIATE_TYPE_SELECT = 3'd0;
				WRITEBACK_SELECT = 2'd0;
			end
			opcode_pkg_OPC_CSR: begin
				REGISTER_WRITE_ENABLE = INSTRUCTION_FUNCT3 != opcode_pkg_FNC_PRIV;
				WRITEBACK_SELECT = 2'd3;
				if ((INSTRUCTION_FUNCT3 == opcode_pkg_FNC_RW) || (INSTRUCTION_FUNCT3 == opcode_pkg_FNC_RWI))
					CSR_WRITE_ENABLE = 1'b1;
				else if (INSTRUCTION_FUNCT3 != opcode_pkg_FNC_PRIV)
					CSR_WRITE_ENABLE = INSTRUCTION_REGISTER1_FIELD != 5'd0;
				if (((INSTRUCTION_FUNCT3 == opcode_pkg_FNC_RWI) || (INSTRUCTION_FUNCT3 == opcode_pkg_FNC_RSI)) || (INSTRUCTION_FUNCT3 == opcode_pkg_FNC_RCI)) begin
					CSR_WRITE_USING_IMMEDIATE = 1'b1;
					IMMEDIATE_TYPE_SELECT = 3'd5;
				end
				else begin
					CSR_WRITE_USING_IMMEDIATE = 1'b0;
					IMMEDIATE_TYPE_SELECT = 3'd0;
				end
			end
			default: begin
				REGISTER_WRITE_ENABLE = 1'b0;
				MEMORY_READ_ENABLE = 1'b0;
				MEMORY_WRITE_ENABLE = 1'b0;
				CSR_WRITE_ENABLE = 1'b0;
				CSR_WRITE_USING_IMMEDIATE = 1'b0;
				ALU_INPUT_A_IS_PC = 1'b0;
				ALU_INPUT_B_IS_IMMEDIATE = 1'b0;
				ALU_IS_WORD_OPERATION = 1'b0;
				IS_A_MULTIPLY_DIVIDE_INSTRUCTION = 1'b0;
				IS_A_BRANCH_INSTRUCTION = 1'b0;
				IS_A_JAL_INSTRUCTION = 1'b0;
				IS_A_JALR_INSTRUCTION = 1'b0;
				IMMEDIATE_TYPE_SELECT = 3'd0;
				WRITEBACK_SELECT = 2'd0;
			end
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module ImmediateGenerator (
	INSTRUCTION,
	IMMEDIATE_TYPE_SELECT,
	IMMEDIATE
);
	reg _sv2v_0;
	input wire [31:0] INSTRUCTION;
	input wire [2:0] IMMEDIATE_TYPE_SELECT;
	output reg [63:0] IMMEDIATE;
	wire [63:0] I_TYPE_IMMEDIATE;
	wire [63:0] S_TYPE_IMMEDIATE;
	wire [63:0] B_TYPE_IMMEDIATE;
	wire [63:0] U_TYPE_IMMEDIATE;
	wire [63:0] J_TYPE_IMMEDIATE;
	wire [63:0] Z_TYPE_IMMEDIATE;
	assign I_TYPE_IMMEDIATE = {{52 {INSTRUCTION[31]}}, INSTRUCTION[31:20]};
	assign S_TYPE_IMMEDIATE = {{52 {INSTRUCTION[31]}}, INSTRUCTION[31:25], INSTRUCTION[11:7]};
	assign B_TYPE_IMMEDIATE = {{51 {INSTRUCTION[31]}}, INSTRUCTION[31], INSTRUCTION[7], INSTRUCTION[30:25], INSTRUCTION[11:8], 1'b0};
	assign U_TYPE_IMMEDIATE = {{32 {INSTRUCTION[31]}}, INSTRUCTION[31:12], 12'b000000000000};
	assign J_TYPE_IMMEDIATE = {{43 {INSTRUCTION[31]}}, INSTRUCTION[31], INSTRUCTION[19:12], INSTRUCTION[20], INSTRUCTION[30:21], 1'b0};
	assign Z_TYPE_IMMEDIATE = {59'd0, INSTRUCTION[19:15]};
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (IMMEDIATE_TYPE_SELECT)
			3'd0: IMMEDIATE = I_TYPE_IMMEDIATE;
			3'd1: IMMEDIATE = S_TYPE_IMMEDIATE;
			3'd2: IMMEDIATE = B_TYPE_IMMEDIATE;
			3'd3: IMMEDIATE = U_TYPE_IMMEDIATE;
			3'd4: IMMEDIATE = J_TYPE_IMMEDIATE;
			3'd5: IMMEDIATE = Z_TYPE_IMMEDIATE;
			default: IMMEDIATE = 64'd0;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module RegisterFile (
	clk,
	reset,
	REGISTER_WRITE_ENABLE,
	READ_ADDRESS1,
	READ_ADDRESS2,
	WRITE_ADDRESS,
	WRITE_DATA,
	READ_DATA1,
	READ_DATA2,
	DEBUG_READ_ADDRESS,
	DEBUG_READ_DATA
);
	input wire clk;
	input wire reset;
	input wire REGISTER_WRITE_ENABLE;
	input wire [4:0] READ_ADDRESS1;
	input wire [4:0] READ_ADDRESS2;
	input wire [4:0] WRITE_ADDRESS;
	input wire [63:0] WRITE_DATA;
	output wire [63:0] READ_DATA1;
	output wire [63:0] READ_DATA2;
	input wire [4:0] DEBUG_READ_ADDRESS;
	output wire [63:0] DEBUG_READ_DATA;
	parameter signed [31:0] DEPTH = 32;
	reg [63:0] MEMORY [1:DEPTH - 1];
	integer MEMORY_INDEX;
	initial for (MEMORY_INDEX = 1; MEMORY_INDEX < DEPTH; MEMORY_INDEX = MEMORY_INDEX + 1)
		MEMORY[MEMORY_INDEX] = 64'd0;
	assign READ_DATA1 = (READ_ADDRESS1 == 5'd0 ? 64'd0 : MEMORY[READ_ADDRESS1]);
	assign READ_DATA2 = (READ_ADDRESS2 == 5'd0 ? 64'd0 : MEMORY[READ_ADDRESS2]);
	assign DEBUG_READ_DATA = (DEBUG_READ_ADDRESS == 5'd0 ? 64'd0 : MEMORY[DEBUG_READ_ADDRESS]);
	always @(posedge clk)
		if ((!reset && REGISTER_WRITE_ENABLE) && (WRITE_ADDRESS != 5'd0))
			MEMORY[WRITE_ADDRESS] <= WRITE_DATA;
endmodule
`default_nettype wire
`default_nettype none
module BranchComparator (
	A,
	B,
	BRANCH_FUNCT3,
	BRANCH_TAKEN
);
	reg _sv2v_0;
	input wire [63:0] A;
	input wire [63:0] B;
	input wire [2:0] BRANCH_FUNCT3;
	output reg BRANCH_TAKEN;
	reg BRANCH_EQUALS;
	reg BRANCH_LT_SIGNED;
	reg BRANCH_LT_UNSIGNED;
	wire [63:0] DIFFERENCE;
	wire NO_BORROW;
	ParallelPrefixAdder #(.WIDTH(64)) compare_subtractor(
		.A(A),
		.B(~B),
		.CARRY_IN(1'b1),
		.SUM(DIFFERENCE),
		.CARRY_OUT(NO_BORROW)
	);
	localparam [2:0] opcode_pkg_FNC_BEQ = 3'b000;
	localparam [2:0] opcode_pkg_FNC_BGE = 3'b101;
	localparam [2:0] opcode_pkg_FNC_BGEU = 3'b111;
	localparam [2:0] opcode_pkg_FNC_BLT = 3'b100;
	localparam [2:0] opcode_pkg_FNC_BLTU = 3'b110;
	localparam [2:0] opcode_pkg_FNC_BNE = 3'b001;
	always @(*) begin
		if (_sv2v_0)
			;
		BRANCH_EQUALS = A == B;
		BRANCH_LT_UNSIGNED = !NO_BORROW;
		BRANCH_LT_SIGNED = (A[63] != B[63] ? A[63] : DIFFERENCE[63]);
		(* full_case, parallel_case *)
		case (BRANCH_FUNCT3)
			opcode_pkg_FNC_BEQ: BRANCH_TAKEN = BRANCH_EQUALS;
			opcode_pkg_FNC_BNE: BRANCH_TAKEN = ~BRANCH_EQUALS;
			opcode_pkg_FNC_BLT: BRANCH_TAKEN = BRANCH_LT_SIGNED;
			opcode_pkg_FNC_BGE: BRANCH_TAKEN = ~BRANCH_LT_SIGNED;
			opcode_pkg_FNC_BLTU: BRANCH_TAKEN = BRANCH_LT_UNSIGNED;
			opcode_pkg_FNC_BGEU: BRANCH_TAKEN = ~BRANCH_LT_UNSIGNED;
			default: BRANCH_TAKEN = 1'b0;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module BranchControl (
	IS_A_BRANCH_INSTRUCTION,
	IS_A_JAL_INSTRUCTION,
	IS_A_JALR_INSTRUCTION,
	ACTUALLY_TAKEN_BRANCH,
	PREDICTED_BRANCH_TAKEN,
	PC_ADD_4,
	BRANCH_TARGET,
	JALR_TARGET,
	JALR_PREDICTION_CORRECT,
	BRANCH_WAS_ACTUALLY_TAKEN,
	PREDICTION_WAS_WRONG,
	FLUSH,
	UPDATE_BRANCH_PREDICTOR,
	ADJUST_NEXT_PC
);
	reg _sv2v_0;
	input wire IS_A_BRANCH_INSTRUCTION;
	input wire IS_A_JAL_INSTRUCTION;
	input wire IS_A_JALR_INSTRUCTION;
	input wire ACTUALLY_TAKEN_BRANCH;
	input wire PREDICTED_BRANCH_TAKEN;
	input wire [63:0] PC_ADD_4;
	input wire [63:0] BRANCH_TARGET;
	input wire [63:0] JALR_TARGET;
	input wire JALR_PREDICTION_CORRECT;
	output reg BRANCH_WAS_ACTUALLY_TAKEN;
	output reg PREDICTION_WAS_WRONG;
	output reg FLUSH;
	output reg UPDATE_BRANCH_PREDICTOR;
	output reg [63:0] ADJUST_NEXT_PC;
	always @(*) begin
		if (_sv2v_0)
			;
		BRANCH_WAS_ACTUALLY_TAKEN = 1'b0;
		PREDICTION_WAS_WRONG = 1'b0;
		FLUSH = 1'b0;
		UPDATE_BRANCH_PREDICTOR = 1'b0;
		ADJUST_NEXT_PC = PC_ADD_4;
		if (IS_A_BRANCH_INSTRUCTION) begin
			BRANCH_WAS_ACTUALLY_TAKEN = ACTUALLY_TAKEN_BRANCH;
			UPDATE_BRANCH_PREDICTOR = 1'b1;
			ADJUST_NEXT_PC = (ACTUALLY_TAKEN_BRANCH ? BRANCH_TARGET : PC_ADD_4);
			PREDICTION_WAS_WRONG = ACTUALLY_TAKEN_BRANCH != PREDICTED_BRANCH_TAKEN;
			FLUSH = ACTUALLY_TAKEN_BRANCH != PREDICTED_BRANCH_TAKEN;
		end
		else if (IS_A_JAL_INSTRUCTION) begin
			BRANCH_WAS_ACTUALLY_TAKEN = 1'b1;
			ADJUST_NEXT_PC = BRANCH_TARGET;
			PREDICTION_WAS_WRONG = 1'b0;
			FLUSH = 1'b0;
		end
		else if (IS_A_JALR_INSTRUCTION) begin
			BRANCH_WAS_ACTUALLY_TAKEN = 1'b1;
			ADJUST_NEXT_PC = JALR_TARGET;
			PREDICTION_WAS_WRONG = !JALR_PREDICTION_CORRECT;
			FLUSH = !JALR_PREDICTION_CORRECT;
		end
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module GSharePredictor (
	clk,
	reset,
	ENABLE,
	FETCH_PC,
	FETCH_PREDICTED_TAKEN,
	FETCH_PREDICTION_INDEX,
	GLOBAL_HISTORY,
	SPECULATIVE_UPDATE,
	SPECULATIVE_TAKEN,
	UPDATE_PREDICTION,
	UPDATE_PREDICTION_INDEX,
	ACTUAL_BRANCH_TAKEN,
	RESTORE_HISTORY,
	RESTORE_HISTORY_VALUE
);
	parameter signed [31:0] HISTORY_BITS = 4;
	input wire clk;
	input wire reset;
	input wire ENABLE;
	input wire [63:0] FETCH_PC;
	output wire FETCH_PREDICTED_TAKEN;
	output wire [HISTORY_BITS - 1:0] FETCH_PREDICTION_INDEX;
	output wire [HISTORY_BITS - 1:0] GLOBAL_HISTORY;
	input wire SPECULATIVE_UPDATE;
	input wire SPECULATIVE_TAKEN;
	input wire UPDATE_PREDICTION;
	input wire [HISTORY_BITS - 1:0] UPDATE_PREDICTION_INDEX;
	input wire ACTUAL_BRANCH_TAKEN;
	input wire RESTORE_HISTORY;
	input wire [HISTORY_BITS - 1:0] RESTORE_HISTORY_VALUE;
	localparam signed [31:0] BRANCH_HISTORY_TABLE_ENTRIES = 1 << HISTORY_BITS;
	reg [(2 * BRANCH_HISTORY_TABLE_ENTRIES) - 1:0] BRANCH_HISTORY_TABLE;
	reg [HISTORY_BITS - 1:0] GLOBAL_HISTORY_REGISTER;
	wire [1:0] FETCH_COUNTER;
	wire [1:0] UPDATE_COUNTER;
	assign GLOBAL_HISTORY = GLOBAL_HISTORY_REGISTER;
	assign FETCH_PREDICTION_INDEX = FETCH_PC[HISTORY_BITS + 1:2] ^ GLOBAL_HISTORY_REGISTER;
	assign FETCH_COUNTER = BRANCH_HISTORY_TABLE[2 * FETCH_PREDICTION_INDEX+:2];
	assign FETCH_PREDICTED_TAKEN = ENABLE && FETCH_COUNTER[1];
	assign UPDATE_COUNTER = BRANCH_HISTORY_TABLE[2 * UPDATE_PREDICTION_INDEX+:2];
	always @(posedge clk)
		if (reset) begin
			GLOBAL_HISTORY_REGISTER <= 1'sb0;
			BRANCH_HISTORY_TABLE <= {BRANCH_HISTORY_TABLE_ENTRIES {2'b10}};
		end
		else begin
			if (RESTORE_HISTORY)
				GLOBAL_HISTORY_REGISTER <= RESTORE_HISTORY_VALUE;
			else if (SPECULATIVE_UPDATE)
				GLOBAL_HISTORY_REGISTER <= {GLOBAL_HISTORY_REGISTER[HISTORY_BITS - 2:0], SPECULATIVE_TAKEN};
			if (UPDATE_PREDICTION)
				(* full_case, parallel_case *)
				case (UPDATE_COUNTER)
					2'b00: BRANCH_HISTORY_TABLE[2 * UPDATE_PREDICTION_INDEX+:2] <= (ACTUAL_BRANCH_TAKEN ? 2'b01 : 2'b00);
					2'b01: BRANCH_HISTORY_TABLE[2 * UPDATE_PREDICTION_INDEX+:2] <= (ACTUAL_BRANCH_TAKEN ? 2'b10 : 2'b00);
					2'b10: BRANCH_HISTORY_TABLE[2 * UPDATE_PREDICTION_INDEX+:2] <= (ACTUAL_BRANCH_TAKEN ? 2'b11 : 2'b01);
					2'b11: BRANCH_HISTORY_TABLE[2 * UPDATE_PREDICTION_INDEX+:2] <= (ACTUAL_BRANCH_TAKEN ? 2'b11 : 2'b10);
					default: BRANCH_HISTORY_TABLE[2 * UPDATE_PREDICTION_INDEX+:2] <= 2'b10;
				endcase
		end
	wire UNUSED_PC_BITS;
	assign UNUSED_PC_BITS = ^{FETCH_PC[63:HISTORY_BITS + 2], FETCH_PC[1:0]};
endmodule
`default_nettype wire
`default_nettype none
module BranchTargetBuffer (
	clk,
	reset,
	FETCH_PC,
	HIT,
	HIT_IS_JAL,
	PREDICTED_TARGET,
	UPDATE,
	UPDATE_PC,
	UPDATE_TARGET,
	UPDATE_IS_JAL
);
	parameter signed [31:0] ENTRIES = 16;
	input wire clk;
	input wire reset;
	input wire [63:0] FETCH_PC;
	output wire HIT;
	output wire HIT_IS_JAL;
	output wire [63:0] PREDICTED_TARGET;
	input wire UPDATE;
	input wire [63:0] UPDATE_PC;
	input wire [63:0] UPDATE_TARGET;
	input wire UPDATE_IS_JAL;
	localparam signed [31:0] INDEX_BITS = $clog2(ENTRIES);
	localparam signed [31:0] TAG_LOW = INDEX_BITS + 2;
	reg [ENTRIES - 1:0] ENTRY_VALID;
	reg [ENTRIES - 1:0] ENTRY_IS_JAL;
	reg [31 - TAG_LOW:0] ENTRY_TAG [0:ENTRIES - 1];
	reg [31:0] ENTRY_TARGET [0:ENTRIES - 1];
	wire [INDEX_BITS - 1:0] FETCH_INDEX;
	wire [INDEX_BITS - 1:0] UPDATE_INDEX;
	assign FETCH_INDEX = FETCH_PC[TAG_LOW - 1:2];
	assign UPDATE_INDEX = UPDATE_PC[TAG_LOW - 1:2];
	assign HIT = (ENTRY_VALID[FETCH_INDEX] && (ENTRY_TAG[FETCH_INDEX] == FETCH_PC[31:TAG_LOW])) && (FETCH_PC[63:32] == 32'd0);
	assign HIT_IS_JAL = ENTRY_IS_JAL[FETCH_INDEX];
	assign PREDICTED_TARGET = {32'd0, ENTRY_TARGET[FETCH_INDEX]};
	always @(posedge clk)
		if (reset) begin
			ENTRY_VALID <= 1'sb0;
			ENTRY_IS_JAL <= 1'sb0;
		end
		else if (UPDATE) begin
			ENTRY_VALID[UPDATE_INDEX] <= 1'b1;
			ENTRY_IS_JAL[UPDATE_INDEX] <= UPDATE_IS_JAL;
		end
	always @(posedge clk)
		if (!reset && UPDATE) begin
			ENTRY_TAG[UPDATE_INDEX] <= UPDATE_PC[31:TAG_LOW];
			ENTRY_TARGET[UPDATE_INDEX] <= UPDATE_TARGET[31:0];
		end
	wire UNUSED_BITS;
	assign UNUSED_BITS = ^{UPDATE_PC[63:32], UPDATE_PC[1:0], UPDATE_TARGET[63:32], FETCH_PC[1:0]};
endmodule
`default_nettype wire
`default_nettype none
module ReturnAddressStack (
	clk,
	reset,
	TOP_ADDRESS,
	POINTER,
	PUSH,
	POP,
	PUSH_ADDRESS,
	RESTORE,
	RESTORE_POINTER
);
	parameter signed [31:0] DEPTH = 8;
	input wire clk;
	input wire reset;
	output wire [63:0] TOP_ADDRESS;
	output wire [$clog2(DEPTH) - 1:0] POINTER;
	input wire PUSH;
	input wire POP;
	input wire [63:0] PUSH_ADDRESS;
	input wire RESTORE;
	input wire [$clog2(DEPTH) - 1:0] RESTORE_POINTER;
	reg [63:0] STACK [0:DEPTH - 1];
	reg [$clog2(DEPTH) - 1:0] TOP_POINTER;
	assign TOP_ADDRESS = STACK[TOP_POINTER];
	assign POINTER = TOP_POINTER;
	integer STACK_INDEX;
	initial for (STACK_INDEX = 0; STACK_INDEX < DEPTH; STACK_INDEX = STACK_INDEX + 1)
		STACK[STACK_INDEX] = 64'd0;
	always @(posedge clk)
		if (reset)
			TOP_POINTER <= 1'sb0;
		else if (RESTORE)
			TOP_POINTER <= RESTORE_POINTER;
		else if (PUSH) begin
			TOP_POINTER <= TOP_POINTER + 1'b1;
			STACK[TOP_POINTER + 1'b1] <= PUSH_ADDRESS;
		end
		else if (POP)
			TOP_POINTER <= TOP_POINTER - 1'b1;
endmodule
`default_nettype wire
`default_nettype none
module TournamentChooser (
	clk,
	reset,
	ENABLE,
	FETCH_PC,
	BHT_PREDICTED_TAKEN,
	CHOOSE_GSHARE,
	UPDATE,
	UPDATE_PC,
	ACTUAL_BRANCH_TAKEN,
	BHT_WAS_TAKEN,
	GSHARE_WAS_TAKEN
);
	parameter signed [31:0] INDEX_BITS = 7;
	input wire clk;
	input wire reset;
	input wire ENABLE;
	input wire [63:0] FETCH_PC;
	output wire BHT_PREDICTED_TAKEN;
	output wire CHOOSE_GSHARE;
	input wire UPDATE;
	input wire [63:0] UPDATE_PC;
	input wire ACTUAL_BRANCH_TAKEN;
	input wire BHT_WAS_TAKEN;
	input wire GSHARE_WAS_TAKEN;
	localparam signed [31:0] ENTRIES = 1 << INDEX_BITS;
	reg [(2 * ENTRIES) - 1:0] BRANCH_HISTORY_TABLE;
	reg [(2 * ENTRIES) - 1:0] CHOOSER_TABLE;
	wire [INDEX_BITS - 1:0] FETCH_INDEX;
	wire [INDEX_BITS - 1:0] UPDATE_INDEX;
	assign FETCH_INDEX = FETCH_PC[INDEX_BITS + 1:2];
	assign UPDATE_INDEX = UPDATE_PC[INDEX_BITS + 1:2];
	wire [1:0] FETCH_BHT_COUNTER;
	wire [1:0] FETCH_CHOOSER_COUNTER;
	wire [1:0] UPDATE_BHT_COUNTER;
	wire [1:0] UPDATE_CHOOSER_COUNTER;
	assign FETCH_BHT_COUNTER = BRANCH_HISTORY_TABLE[2 * FETCH_INDEX+:2];
	assign FETCH_CHOOSER_COUNTER = CHOOSER_TABLE[2 * FETCH_INDEX+:2];
	assign UPDATE_BHT_COUNTER = BRANCH_HISTORY_TABLE[2 * UPDATE_INDEX+:2];
	assign UPDATE_CHOOSER_COUNTER = CHOOSER_TABLE[2 * UPDATE_INDEX+:2];
	assign BHT_PREDICTED_TAKEN = ENABLE && FETCH_BHT_COUNTER[1];
	assign CHOOSE_GSHARE = FETCH_CHOOSER_COUNTER[1];
	wire GSHARE_WAS_RIGHT;
	wire BHT_WAS_RIGHT;
	assign GSHARE_WAS_RIGHT = GSHARE_WAS_TAKEN == ACTUAL_BRANCH_TAKEN;
	assign BHT_WAS_RIGHT = BHT_WAS_TAKEN == ACTUAL_BRANCH_TAKEN;
	always @(posedge clk)
		if (reset) begin
			BRANCH_HISTORY_TABLE <= {ENTRIES {2'b10}};
			CHOOSER_TABLE <= {ENTRIES {2'b01}};
		end
		else if (UPDATE) begin
			if (ACTUAL_BRANCH_TAKEN && (UPDATE_BHT_COUNTER != 2'b11))
				BRANCH_HISTORY_TABLE[2 * UPDATE_INDEX+:2] <= UPDATE_BHT_COUNTER + 2'b01;
			else if (!ACTUAL_BRANCH_TAKEN && (UPDATE_BHT_COUNTER != 2'b00))
				BRANCH_HISTORY_TABLE[2 * UPDATE_INDEX+:2] <= UPDATE_BHT_COUNTER - 2'b01;
			if ((GSHARE_WAS_RIGHT && !BHT_WAS_RIGHT) && (UPDATE_CHOOSER_COUNTER != 2'b11))
				CHOOSER_TABLE[2 * UPDATE_INDEX+:2] <= UPDATE_CHOOSER_COUNTER + 2'b01;
			else if ((BHT_WAS_RIGHT && !GSHARE_WAS_RIGHT) && (UPDATE_CHOOSER_COUNTER != 2'b00))
				CHOOSER_TABLE[2 * UPDATE_INDEX+:2] <= UPDATE_CHOOSER_COUNTER - 2'b01;
		end
	wire UNUSED_BITS;
	assign UNUSED_BITS = ^{FETCH_PC[63:INDEX_BITS + 2], FETCH_PC[1:0], UPDATE_PC[63:INDEX_BITS + 2], UPDATE_PC[1:0]};
endmodule
`default_nettype wire
`default_nettype none
module LoadControl (
	LOAD_FUNCT3,
	MEMORY_ADDRESS,
	MEMORY_INFO,
	DATA_TO_LOAD
);
	reg _sv2v_0;
	input wire [2:0] LOAD_FUNCT3;
	input wire [63:0] MEMORY_ADDRESS;
	input wire [63:0] MEMORY_INFO;
	output reg [63:0] DATA_TO_LOAD;
	wire [2:0] BYTE_FORMATTING = MEMORY_ADDRESS[2:0];
	wire [7:0] BYTE0 = MEMORY_INFO[7:0];
	wire [7:0] BYTE1 = MEMORY_INFO[15:8];
	wire [7:0] BYTE2 = MEMORY_INFO[23:16];
	wire [7:0] BYTE3 = MEMORY_INFO[31:24];
	wire [7:0] BYTE4 = MEMORY_INFO[39:32];
	wire [7:0] BYTE5 = MEMORY_INFO[47:40];
	wire [7:0] BYTE6 = MEMORY_INFO[55:48];
	wire [7:0] BYTE7 = MEMORY_INFO[63:56];
	wire [15:0] HALF0 = MEMORY_INFO[15:0];
	wire [15:0] HALF1 = MEMORY_INFO[31:16];
	wire [15:0] HALF2 = MEMORY_INFO[47:32];
	wire [15:0] HALF3 = MEMORY_INFO[63:48];
	wire [31:0] WORD0 = MEMORY_INFO[31:0];
	wire [31:0] WORD1 = MEMORY_INFO[63:32];
	wire [7:0] SELECT_BYTE_TO_LOAD = (BYTE_FORMATTING == 3'd0 ? BYTE0 : (BYTE_FORMATTING == 3'd1 ? BYTE1 : (BYTE_FORMATTING == 3'd2 ? BYTE2 : (BYTE_FORMATTING == 3'd3 ? BYTE3 : (BYTE_FORMATTING == 3'd4 ? BYTE4 : (BYTE_FORMATTING == 3'd5 ? BYTE5 : (BYTE_FORMATTING == 3'd6 ? BYTE6 : BYTE7)))))));
	wire [15:0] SELECT_HALF_TO_LOAD = (BYTE_FORMATTING[2:1] == 2'd0 ? HALF0 : (BYTE_FORMATTING[2:1] == 2'd1 ? HALF1 : (BYTE_FORMATTING[2:1] == 2'd2 ? HALF2 : HALF3)));
	wire [31:0] SELECT_WORD_TO_LOAD = (BYTE_FORMATTING[2] ? WORD1 : WORD0);
	localparam [2:0] opcode_pkg_FNC_LB = 3'b000;
	localparam [2:0] opcode_pkg_FNC_LBU = 3'b100;
	localparam [2:0] opcode_pkg_FNC_LD = 3'b011;
	localparam [2:0] opcode_pkg_FNC_LH = 3'b001;
	localparam [2:0] opcode_pkg_FNC_LHU = 3'b101;
	localparam [2:0] opcode_pkg_FNC_LW = 3'b010;
	localparam [2:0] opcode_pkg_FNC_LWU = 3'b110;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (LOAD_FUNCT3)
			opcode_pkg_FNC_LB: DATA_TO_LOAD = {{56 {SELECT_BYTE_TO_LOAD[7]}}, SELECT_BYTE_TO_LOAD};
			opcode_pkg_FNC_LH: DATA_TO_LOAD = {{48 {SELECT_HALF_TO_LOAD[15]}}, SELECT_HALF_TO_LOAD};
			opcode_pkg_FNC_LW: DATA_TO_LOAD = {{32 {SELECT_WORD_TO_LOAD[31]}}, SELECT_WORD_TO_LOAD};
			opcode_pkg_FNC_LD: DATA_TO_LOAD = MEMORY_INFO;
			opcode_pkg_FNC_LBU: DATA_TO_LOAD = {56'd0, SELECT_BYTE_TO_LOAD};
			opcode_pkg_FNC_LHU: DATA_TO_LOAD = {48'd0, SELECT_HALF_TO_LOAD};
			opcode_pkg_FNC_LWU: DATA_TO_LOAD = {32'd0, SELECT_WORD_TO_LOAD};
			default: DATA_TO_LOAD = 64'd0;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module StoreControl (
	STORE_FUNCT3,
	MEMORY_ADDRESS,
	MEMORY_INFO,
	WRITE_MASK_FOR_STORE,
	DATA_TO_STORE
);
	reg _sv2v_0;
	input wire [2:0] STORE_FUNCT3;
	input wire [63:0] MEMORY_ADDRESS;
	input wire [63:0] MEMORY_INFO;
	output reg [7:0] WRITE_MASK_FOR_STORE;
	output reg [63:0] DATA_TO_STORE;
	wire [2:0] BYTE_FORMATTING = MEMORY_ADDRESS[2:0];
	wire [7:0] BYTE_TO_STORE = MEMORY_INFO[7:0];
	wire [15:0] HALF_TO_STORE = MEMORY_INFO[15:0];
	wire [31:0] WORD_TO_STORE = MEMORY_INFO[31:0];
	wire [63:0] DOUBLE_TO_STORE = MEMORY_INFO;
	wire [63:0] STORE_BYTE_ALIGNED = {56'd0, BYTE_TO_STORE} << (8 * BYTE_FORMATTING);
	wire [7:0] STORE_BYTE_MASK = 8'b00000001 << BYTE_FORMATTING;
	wire [63:0] STORE_HALF_ALIGNED = {48'd0, HALF_TO_STORE} << (16 * BYTE_FORMATTING[2:1]);
	wire [7:0] STORE_HALF_MASK = 8'b00000011 << (2 * BYTE_FORMATTING[2:1]);
	wire [63:0] STORE_WORD_ALIGNED = (BYTE_FORMATTING[2] ? {WORD_TO_STORE, 32'd0} : {32'd0, WORD_TO_STORE});
	wire [7:0] STORE_WORD_MASK = (BYTE_FORMATTING[2] ? 8'b11110000 : 8'b00001111);
	localparam [2:0] opcode_pkg_FNC_SB = 3'b000;
	localparam [2:0] opcode_pkg_FNC_SD = 3'b011;
	localparam [2:0] opcode_pkg_FNC_SH = 3'b001;
	localparam [2:0] opcode_pkg_FNC_SW = 3'b010;
	always @(*) begin
		if (_sv2v_0)
			;
		WRITE_MASK_FOR_STORE = 8'b00000000;
		DATA_TO_STORE = 64'd0;
		(* full_case, parallel_case *)
		case (STORE_FUNCT3)
			opcode_pkg_FNC_SB: begin
				WRITE_MASK_FOR_STORE = STORE_BYTE_MASK;
				DATA_TO_STORE = STORE_BYTE_ALIGNED;
			end
			opcode_pkg_FNC_SH: begin
				WRITE_MASK_FOR_STORE = STORE_HALF_MASK;
				DATA_TO_STORE = STORE_HALF_ALIGNED;
			end
			opcode_pkg_FNC_SW: begin
				WRITE_MASK_FOR_STORE = STORE_WORD_MASK;
				DATA_TO_STORE = STORE_WORD_ALIGNED;
			end
			opcode_pkg_FNC_SD: begin
				WRITE_MASK_FOR_STORE = 8'b11111111;
				DATA_TO_STORE = DOUBLE_TO_STORE;
			end
			default: begin
				WRITE_MASK_FOR_STORE = 8'b00000000;
				DATA_TO_STORE = 64'd0;
			end
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module WriteControl (
	REGISTER_WRITE_ENABLE_INPUT,
	WRITEBACK_SELECT,
	ALU_RESULT,
	MEMORY_DATA,
	PC_ADD_4,
	CSR_DATA,
	REGISTER_WRITE_ENABLE_OUTPUT,
	WRITEBACK_DATA
);
	reg _sv2v_0;
	input wire REGISTER_WRITE_ENABLE_INPUT;
	input wire [1:0] WRITEBACK_SELECT;
	input wire [63:0] ALU_RESULT;
	input wire [63:0] MEMORY_DATA;
	input wire [63:0] PC_ADD_4;
	input wire [63:0] CSR_DATA;
	output reg REGISTER_WRITE_ENABLE_OUTPUT;
	output reg [63:0] WRITEBACK_DATA;
	always @(*) begin
		if (_sv2v_0)
			;
		REGISTER_WRITE_ENABLE_OUTPUT = REGISTER_WRITE_ENABLE_INPUT;
		WRITEBACK_DATA = 64'd0;
		(* full_case, parallel_case *)
		case (WRITEBACK_SELECT)
			2'd0: WRITEBACK_DATA = ALU_RESULT;
			2'd1: WRITEBACK_DATA = MEMORY_DATA;
			2'd2: WRITEBACK_DATA = PC_ADD_4;
			2'd3: WRITEBACK_DATA = CSR_DATA;
			default: WRITEBACK_DATA = 64'd0;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module CSRFile (
	clk,
	reset,
	CSR_WRITE_ENABLE,
	CSR_ADDRESS,
	CSR_OPERATION,
	CSR_WRITE_DATA,
	INSTRUCTION_RETIRED,
	PERFORMANCE_EVENTS,
	TAKE_TRAP,
	TRAP_PC,
	TRAP_CAUSE,
	TIMER_INTERRUPT_LINE,
	EXTERNAL_INTERRUPT_LINE,
	INTERRUPT_REQUEST,
	INTERRUPT_IS_EXTERNAL,
	RETURN_FROM_TRAP,
	TRAP_VECTOR,
	EXCEPTION_PC,
	CSR_READ_DATA,
	TOHOST
);
	reg _sv2v_0;
	input wire clk;
	input wire reset;
	input wire CSR_WRITE_ENABLE;
	input wire [11:0] CSR_ADDRESS;
	input wire [2:0] CSR_OPERATION;
	input wire [63:0] CSR_WRITE_DATA;
	input wire INSTRUCTION_RETIRED;
	input wire [6:0] PERFORMANCE_EVENTS;
	input wire TAKE_TRAP;
	input wire [63:0] TRAP_PC;
	input wire [63:0] TRAP_CAUSE;
	input wire TIMER_INTERRUPT_LINE;
	input wire EXTERNAL_INTERRUPT_LINE;
	output wire INTERRUPT_REQUEST;
	output wire INTERRUPT_IS_EXTERNAL;
	input wire RETURN_FROM_TRAP;
	output wire [63:0] TRAP_VECTOR;
	output wire [63:0] EXCEPTION_PC;
	output reg [63:0] CSR_READ_DATA;
	output wire [63:0] TOHOST;
	reg [63:0] CSR_TOHOST_REGISTER;
	reg [63:0] CSR_STATUS_REGISTER;
	reg [63:0] CSR_MSTATUS_REGISTER;
	reg [63:0] CSR_MTVEC_REGISTER;
	reg [63:0] CSR_MSCRATCH_REGISTER;
	reg [63:0] CSR_MEPC_REGISTER;
	reg [63:0] CSR_MCAUSE_REGISTER;
	reg [63:0] CSR_MIE_REGISTER;
	reg MIP_MTIP;
	reg MIP_MEIP;
	reg [63:0] CSR_CYCLE_COUNTER;
	reg [63:0] CSR_INSTRET_COUNTER;
	reg CYCLE_CARRY_PENDING;
	reg INSTRET_CARRY_PENDING;
	reg [63:0] CSR_NEW_VALUE;
	wire [63:0] EVENT_COUNT [0:6];
	genvar _gv_EVENT_1;
	generate
		for (_gv_EVENT_1 = 0; _gv_EVENT_1 < 7; _gv_EVENT_1 = _gv_EVENT_1 + 1) begin : performance_counter
			localparam EVENT = _gv_EVENT_1;
			EventCounter counter(
				.clk(clk),
				.reset(reset),
				.INCREMENT(PERFORMANCE_EVENTS[EVENT]),
				.COUNT(EVENT_COUNT[EVENT])
			);
		end
	endgenerate
	wire [31:0] CYCLE_LOW_NEXT;
	wire [31:0] CYCLE_HIGH_NEXT;
	wire [31:0] INSTRET_LOW_NEXT;
	wire [31:0] INSTRET_HIGH_NEXT;
	wire CYCLE_LOW_CARRY;
	wire CYCLE_HIGH_CARRY_UNUSED;
	wire INSTRET_LOW_CARRY;
	wire INSTRET_HIGH_CARRY_UNUSED;
	ParallelPrefixAdder #(.WIDTH(32)) cycle_low_incrementer(
		.A(CSR_CYCLE_COUNTER[31:0]),
		.B(32'd0),
		.CARRY_IN(1'b1),
		.SUM(CYCLE_LOW_NEXT),
		.CARRY_OUT(CYCLE_LOW_CARRY)
	);
	ParallelPrefixAdder #(.WIDTH(32)) cycle_high_incrementer(
		.A(CSR_CYCLE_COUNTER[63:32]),
		.B(32'd0),
		.CARRY_IN(CYCLE_CARRY_PENDING),
		.SUM(CYCLE_HIGH_NEXT),
		.CARRY_OUT(CYCLE_HIGH_CARRY_UNUSED)
	);
	ParallelPrefixAdder #(.WIDTH(32)) instret_low_incrementer(
		.A(CSR_INSTRET_COUNTER[31:0]),
		.B(32'd0),
		.CARRY_IN(1'b1),
		.SUM(INSTRET_LOW_NEXT),
		.CARRY_OUT(INSTRET_LOW_CARRY)
	);
	ParallelPrefixAdder #(.WIDTH(32)) instret_high_incrementer(
		.A(CSR_INSTRET_COUNTER[63:32]),
		.B(32'd0),
		.CARRY_IN(INSTRET_CARRY_PENDING),
		.SUM(INSTRET_HIGH_NEXT),
		.CARRY_OUT(INSTRET_HIGH_CARRY_UNUSED)
	);
	localparam [2:0] opcode_pkg_FNC_RC = 3'b011;
	localparam [2:0] opcode_pkg_FNC_RCI = 3'b111;
	localparam [2:0] opcode_pkg_FNC_RS = 3'b010;
	localparam [2:0] opcode_pkg_FNC_RSI = 3'b110;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (CSR_OPERATION)
			opcode_pkg_FNC_RS, opcode_pkg_FNC_RSI: CSR_NEW_VALUE = CSR_READ_DATA | CSR_WRITE_DATA;
			opcode_pkg_FNC_RC, opcode_pkg_FNC_RCI: CSR_NEW_VALUE = CSR_READ_DATA & ~CSR_WRITE_DATA;
			default: CSR_NEW_VALUE = CSR_WRITE_DATA;
		endcase
	end
	localparam [11:0] const_pkg_CSR_MCAUSE = 12'h342;
	localparam [11:0] const_pkg_CSR_MEPC = 12'h341;
	localparam [11:0] const_pkg_CSR_MIE = 12'h304;
	localparam [11:0] const_pkg_CSR_MSCRATCH = 12'h340;
	localparam [11:0] const_pkg_CSR_MSTATUS = 12'h300;
	localparam [11:0] const_pkg_CSR_MTVEC = 12'h305;
	localparam [11:0] const_pkg_CSR_STATUS = 12'h50a;
	localparam [11:0] const_pkg_CSR_TOHOST = 12'h51e;
	always @(posedge clk)
		if (reset) begin
			CSR_TOHOST_REGISTER <= 64'd0;
			CSR_STATUS_REGISTER <= 64'd0;
			CSR_MSTATUS_REGISTER <= 64'd0;
			CSR_MTVEC_REGISTER <= 64'd0;
			CSR_MSCRATCH_REGISTER <= 64'd0;
			CSR_MEPC_REGISTER <= 64'd0;
			CSR_MCAUSE_REGISTER <= 64'd0;
			CSR_MIE_REGISTER <= 64'd0;
			MIP_MTIP <= 1'b0;
			MIP_MEIP <= 1'b0;
			CSR_CYCLE_COUNTER <= 64'd0;
			CSR_INSTRET_COUNTER <= 64'd0;
			CYCLE_CARRY_PENDING <= 1'b0;
			INSTRET_CARRY_PENDING <= 1'b0;
		end
		else begin
			CSR_CYCLE_COUNTER <= {CYCLE_HIGH_NEXT, CYCLE_LOW_NEXT};
			MIP_MTIP <= TIMER_INTERRUPT_LINE;
			MIP_MEIP <= EXTERNAL_INTERRUPT_LINE;
			CYCLE_CARRY_PENDING <= CYCLE_LOW_CARRY;
			CSR_INSTRET_COUNTER[63:32] <= INSTRET_HIGH_NEXT;
			INSTRET_CARRY_PENDING <= INSTRUCTION_RETIRED && INSTRET_LOW_CARRY;
			if (INSTRUCTION_RETIRED)
				CSR_INSTRET_COUNTER[31:0] <= INSTRET_LOW_NEXT;
			if (TAKE_TRAP) begin
				CSR_MEPC_REGISTER <= {TRAP_PC[63:1], 1'b0};
				CSR_MCAUSE_REGISTER <= TRAP_CAUSE;
				CSR_MSTATUS_REGISTER[7] <= CSR_MSTATUS_REGISTER[3];
				CSR_MSTATUS_REGISTER[3] <= 1'b0;
			end
			else if (RETURN_FROM_TRAP) begin
				CSR_MSTATUS_REGISTER[3] <= CSR_MSTATUS_REGISTER[7];
				CSR_MSTATUS_REGISTER[7] <= 1'b1;
			end
			if (CSR_WRITE_ENABLE)
				(* full_case, parallel_case *)
				case (CSR_ADDRESS)
					const_pkg_CSR_TOHOST: CSR_TOHOST_REGISTER <= CSR_NEW_VALUE;
					const_pkg_CSR_STATUS: CSR_STATUS_REGISTER <= CSR_NEW_VALUE;
					const_pkg_CSR_MSTATUS: CSR_MSTATUS_REGISTER <= CSR_NEW_VALUE;
					const_pkg_CSR_MTVEC: CSR_MTVEC_REGISTER <= CSR_NEW_VALUE;
					const_pkg_CSR_MSCRATCH: CSR_MSCRATCH_REGISTER <= CSR_NEW_VALUE;
					const_pkg_CSR_MEPC: CSR_MEPC_REGISTER <= {CSR_NEW_VALUE[63:1], 1'b0};
					const_pkg_CSR_MCAUSE: CSR_MCAUSE_REGISTER <= CSR_NEW_VALUE;
					const_pkg_CSR_MIE: CSR_MIE_REGISTER <= CSR_NEW_VALUE;
					default:
						;
				endcase
		end
	localparam [11:0] const_pkg_CSR_CYCLE = 12'hc00;
	localparam [11:0] const_pkg_CSR_HARTID = 12'h50b;
	localparam [11:0] const_pkg_CSR_HPMCOUNTER3 = 12'hc03;
	localparam [11:0] const_pkg_CSR_HPMCOUNTER4 = 12'hc04;
	localparam [11:0] const_pkg_CSR_HPMCOUNTER5 = 12'hc05;
	localparam [11:0] const_pkg_CSR_HPMCOUNTER6 = 12'hc06;
	localparam [11:0] const_pkg_CSR_HPMCOUNTER7 = 12'hc07;
	localparam [11:0] const_pkg_CSR_HPMCOUNTER8 = 12'hc08;
	localparam [11:0] const_pkg_CSR_HPMCOUNTER9 = 12'hc09;
	localparam [11:0] const_pkg_CSR_INSTRET = 12'hc02;
	localparam [11:0] const_pkg_CSR_MHARTID = 12'hf14;
	localparam [11:0] const_pkg_CSR_MIP = 12'h344;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (CSR_ADDRESS)
			const_pkg_CSR_TOHOST: CSR_READ_DATA = CSR_TOHOST_REGISTER;
			const_pkg_CSR_STATUS: CSR_READ_DATA = CSR_STATUS_REGISTER;
			const_pkg_CSR_HARTID: CSR_READ_DATA = 64'd0;
			const_pkg_CSR_MSTATUS: CSR_READ_DATA = CSR_MSTATUS_REGISTER;
			const_pkg_CSR_MTVEC: CSR_READ_DATA = CSR_MTVEC_REGISTER;
			const_pkg_CSR_MSCRATCH: CSR_READ_DATA = CSR_MSCRATCH_REGISTER;
			const_pkg_CSR_MEPC: CSR_READ_DATA = CSR_MEPC_REGISTER;
			const_pkg_CSR_MCAUSE: CSR_READ_DATA = CSR_MCAUSE_REGISTER;
			const_pkg_CSR_MIE: CSR_READ_DATA = CSR_MIE_REGISTER;
			const_pkg_CSR_MIP: CSR_READ_DATA = {52'd0, MIP_MEIP, 3'd0, MIP_MTIP, 7'd0};
			const_pkg_CSR_MHARTID: CSR_READ_DATA = 64'd0;
			const_pkg_CSR_CYCLE: CSR_READ_DATA = CSR_CYCLE_COUNTER;
			const_pkg_CSR_INSTRET: CSR_READ_DATA = CSR_INSTRET_COUNTER;
			const_pkg_CSR_HPMCOUNTER3: CSR_READ_DATA = EVENT_COUNT[0];
			const_pkg_CSR_HPMCOUNTER4: CSR_READ_DATA = EVENT_COUNT[1];
			const_pkg_CSR_HPMCOUNTER5: CSR_READ_DATA = EVENT_COUNT[2];
			const_pkg_CSR_HPMCOUNTER6: CSR_READ_DATA = EVENT_COUNT[3];
			const_pkg_CSR_HPMCOUNTER7: CSR_READ_DATA = EVENT_COUNT[4];
			const_pkg_CSR_HPMCOUNTER8: CSR_READ_DATA = EVENT_COUNT[5];
			const_pkg_CSR_HPMCOUNTER9: CSR_READ_DATA = EVENT_COUNT[6];
			default: CSR_READ_DATA = 64'd0;
		endcase
	end
	assign TOHOST = CSR_TOHOST_REGISTER;
	assign TRAP_VECTOR = {CSR_MTVEC_REGISTER[63:2], 2'b00};
	assign EXCEPTION_PC = CSR_MEPC_REGISTER;
	assign INTERRUPT_IS_EXTERNAL = CSR_MIE_REGISTER[11] && MIP_MEIP;
	assign INTERRUPT_REQUEST = CSR_MSTATUS_REGISTER[3] && ((CSR_MIE_REGISTER[7] && MIP_MTIP) || INTERRUPT_IS_EXTERNAL);
	initial _sv2v_0 = 0;
endmodule
module EventCounter (
	clk,
	reset,
	INCREMENT,
	COUNT
);
	input wire clk;
	input wire reset;
	input wire INCREMENT;
	output reg [63:0] COUNT;
	reg CARRY_PENDING;
	wire LOW_CARRY;
	wire HIGH_CARRY_UNUSED;
	wire [31:0] LOW_NEXT;
	wire [31:0] HIGH_NEXT;
	ParallelPrefixAdder #(.WIDTH(32)) low_incrementer(
		.A(COUNT[31:0]),
		.B(32'd0),
		.CARRY_IN(1'b1),
		.SUM(LOW_NEXT),
		.CARRY_OUT(LOW_CARRY)
	);
	ParallelPrefixAdder #(.WIDTH(32)) high_incrementer(
		.A(COUNT[63:32]),
		.B(32'd0),
		.CARRY_IN(CARRY_PENDING),
		.SUM(HIGH_NEXT),
		.CARRY_OUT(HIGH_CARRY_UNUSED)
	);
	always @(posedge clk)
		if (reset) begin
			COUNT <= 64'd0;
			CARRY_PENDING <= 1'b0;
		end
		else begin
			COUNT[63:32] <= HIGH_NEXT;
			CARRY_PENDING <= INCREMENT && LOW_CARRY;
			if (INCREMENT)
				COUNT[31:0] <= LOW_NEXT;
		end
endmodule
`default_nettype wire
`default_nettype none
module InstructionCache (
	clk,
	reset,
	FREEZE,
	FETCH_ADDRESS,
	INSTRUCTION,
	HIT,
	REFILL_ADDRESS,
	REFILL_LINE
);
	parameter signed [31:0] MISS_LATENCY = 10;
	parameter signed [31:0] SETS = 64;
	input wire clk;
	input wire reset;
	input wire FREEZE;
	input wire [63:0] FETCH_ADDRESS;
	output wire [31:0] INSTRUCTION;
	output wire HIT;
	output wire [63:0] REFILL_ADDRESS;
	input wire [255:0] REFILL_LINE;
	localparam signed [31:0] SET_BITS = $clog2(SETS);
	localparam signed [31:0] TAG_BITS = 27 - SET_BITS;
	reg [SETS - 1:0] WAY0_VALID;
	reg [SETS - 1:0] WAY1_VALID;
	reg [TAG_BITS - 1:0] WAY0_TAG [0:SETS - 1];
	reg [TAG_BITS - 1:0] WAY1_TAG [0:SETS - 1];
	reg [255:0] WAY0_DATA [0:SETS - 1];
	reg [255:0] WAY1_DATA [0:SETS - 1];
	reg [SETS - 1:0] LEAST_RECENTLY_USED;
	wire [SET_BITS - 1:0] FETCH_SET;
	wire HIT_WAY0;
	wire HIT_WAY1;
	assign FETCH_SET = FETCH_ADDRESS[SET_BITS + 4:5];
	assign HIT_WAY0 = (WAY0_VALID[FETCH_SET] && (WAY0_TAG[FETCH_SET] == FETCH_ADDRESS[31:SET_BITS + 5])) && (FETCH_ADDRESS[63:32] == 32'd0);
	assign HIT_WAY1 = (WAY1_VALID[FETCH_SET] && (WAY1_TAG[FETCH_SET] == FETCH_ADDRESS[31:SET_BITS + 5])) && (FETCH_ADDRESS[63:32] == 32'd0);
	assign HIT = HIT_WAY0 || HIT_WAY1;
	assign INSTRUCTION = (HIT_WAY1 ? WAY1_DATA[FETCH_SET][32 * FETCH_ADDRESS[4:2]+:32] : WAY0_DATA[FETCH_SET][32 * FETCH_ADDRESS[4:2]+:32]);
	reg REFILL_BUSY;
	reg [5:0] REFILL_CYCLES_LEFT;
	reg [63:0] REFILL_LINE_ADDRESS;
	reg REFILL_IS_DEMAND;
	reg PREFETCH_PENDING;
	reg [63:0] PREFETCH_LINE_ADDRESS;
	wire PREFETCH_PRESENT;
	wire [SET_BITS - 1:0] REFILL_SET;
	wire [SET_BITS - 1:0] PREFETCH_SET;
	wire REFILL_VICTIM_WAY;
	wire INSTALL;
	assign REFILL_SET = REFILL_LINE_ADDRESS[SET_BITS + 4:5];
	assign PREFETCH_SET = PREFETCH_LINE_ADDRESS[SET_BITS + 4:5];
	assign PREFETCH_PRESENT = (WAY0_VALID[PREFETCH_SET] && (WAY0_TAG[PREFETCH_SET] == PREFETCH_LINE_ADDRESS[31:SET_BITS + 5])) || (WAY1_VALID[PREFETCH_SET] && (WAY1_TAG[PREFETCH_SET] == PREFETCH_LINE_ADDRESS[31:SET_BITS + 5]));
	assign REFILL_VICTIM_WAY = (!WAY0_VALID[REFILL_SET] ? 1'b0 : (!WAY1_VALID[REFILL_SET] ? 1'b1 : LEAST_RECENTLY_USED[REFILL_SET]));
	assign INSTALL = REFILL_BUSY && (REFILL_CYCLES_LEFT == 6'd1);
	assign REFILL_ADDRESS = REFILL_LINE_ADDRESS;
	always @(posedge clk)
		if (reset) begin
			WAY0_VALID <= 1'sb0;
			WAY1_VALID <= 1'sb0;
			LEAST_RECENTLY_USED <= 1'sb0;
			REFILL_BUSY <= 1'b0;
			REFILL_CYCLES_LEFT <= 6'd0;
			REFILL_LINE_ADDRESS <= 64'd0;
			REFILL_IS_DEMAND <= 1'b0;
			PREFETCH_PENDING <= 1'b0;
			PREFETCH_LINE_ADDRESS <= 64'd0;
		end
		else if (!FREEZE) begin
			if (HIT)
				LEAST_RECENTLY_USED[FETCH_SET] <= HIT_WAY0;
			if (!REFILL_BUSY) begin
				if (!HIT) begin
					REFILL_BUSY <= 1'b1;
					REFILL_CYCLES_LEFT <= MISS_LATENCY[5:0];
					REFILL_LINE_ADDRESS <= {FETCH_ADDRESS[63:5], 5'b00000};
					REFILL_IS_DEMAND <= 1'b1;
				end
				else if (PREFETCH_PENDING) begin
					PREFETCH_PENDING <= 1'b0;
					if (!PREFETCH_PRESENT) begin
						REFILL_BUSY <= 1'b1;
						REFILL_CYCLES_LEFT <= MISS_LATENCY[5:0];
						REFILL_LINE_ADDRESS <= PREFETCH_LINE_ADDRESS;
						REFILL_IS_DEMAND <= 1'b0;
					end
				end
			end
			else if (INSTALL) begin
				REFILL_BUSY <= 1'b0;
				if (REFILL_VICTIM_WAY)
					WAY1_VALID[REFILL_SET] <= 1'b1;
				else
					WAY0_VALID[REFILL_SET] <= 1'b1;
				LEAST_RECENTLY_USED[REFILL_SET] <= !REFILL_VICTIM_WAY;
				if (REFILL_IS_DEMAND) begin
					PREFETCH_PENDING <= 1'b1;
					PREFETCH_LINE_ADDRESS <= REFILL_LINE_ADDRESS + 64'd32;
				end
			end
			else
				REFILL_CYCLES_LEFT <= REFILL_CYCLES_LEFT - 6'd1;
		end
	always @(posedge clk)
		if ((!reset && !FREEZE) && INSTALL) begin
			if (REFILL_VICTIM_WAY) begin
				WAY1_TAG[REFILL_SET] <= REFILL_LINE_ADDRESS[31:SET_BITS + 5];
				WAY1_DATA[REFILL_SET] <= REFILL_LINE;
			end
			else begin
				WAY0_TAG[REFILL_SET] <= REFILL_LINE_ADDRESS[31:SET_BITS + 5];
				WAY0_DATA[REFILL_SET] <= REFILL_LINE;
			end
		end
endmodule
`default_nettype wire
`default_nettype none
module DataCache (
	clk,
	reset,
	FREEZE,
	LOAD_REQUEST,
	ADDRESS,
	WRITE_MASK,
	WRITE_DATA,
	READ_DATA,
	HIT,
	REFILL_ADDRESS,
	REFILL_LINE
);
	reg _sv2v_0;
	parameter signed [31:0] MISS_LATENCY = 10;
	parameter signed [31:0] SETS = 64;
	input wire clk;
	input wire reset;
	input wire FREEZE;
	input wire LOAD_REQUEST;
	input wire [63:0] ADDRESS;
	input wire [7:0] WRITE_MASK;
	input wire [63:0] WRITE_DATA;
	output wire [63:0] READ_DATA;
	output wire HIT;
	output wire [63:0] REFILL_ADDRESS;
	input wire [255:0] REFILL_LINE;
	localparam signed [31:0] SET_BITS = $clog2(SETS);
	localparam signed [31:0] TAG_BITS = 27 - SET_BITS;
	reg [SETS - 1:0] WAY0_VALID;
	reg [SETS - 1:0] WAY1_VALID;
	reg [TAG_BITS - 1:0] WAY0_TAG [0:SETS - 1];
	reg [TAG_BITS - 1:0] WAY1_TAG [0:SETS - 1];
	reg [255:0] WAY0_DATA [0:SETS - 1];
	reg [255:0] WAY1_DATA [0:SETS - 1];
	reg [SETS - 1:0] LEAST_RECENTLY_USED;
	wire [SET_BITS - 1:0] SET;
	wire HIT_WAY0;
	wire HIT_WAY1;
	wire LINE_PRESENT;
	assign SET = ADDRESS[SET_BITS + 4:5];
	assign HIT_WAY0 = (WAY0_VALID[SET] && (WAY0_TAG[SET] == ADDRESS[31:SET_BITS + 5])) && (ADDRESS[63:32] == 32'd0);
	assign HIT_WAY1 = (WAY1_VALID[SET] && (WAY1_TAG[SET] == ADDRESS[31:SET_BITS + 5])) && (ADDRESS[63:32] == 32'd0);
	assign LINE_PRESENT = HIT_WAY0 || HIT_WAY1;
	assign HIT = !LOAD_REQUEST || LINE_PRESENT;
	assign READ_DATA = (HIT_WAY1 ? WAY1_DATA[SET][64 * ADDRESS[4:3]+:64] : WAY0_DATA[SET][64 * ADDRESS[4:3]+:64]);
	reg REFILL_BUSY;
	reg [5:0] REFILL_CYCLES_LEFT;
	reg [63:0] REFILL_LINE_ADDRESS;
	wire [SET_BITS - 1:0] REFILL_SET;
	wire REFILL_VICTIM_WAY;
	wire INSTALL;
	wire STORE_HIT;
	reg PREFETCH_PENDING;
	reg [63:0] PREFETCH_LINE_ADDRESS;
	wire PREFETCH_PRESENT;
	reg REFILL_IS_DEMAND;
	assign PREFETCH_PRESENT = (WAY0_VALID[PREFETCH_LINE_ADDRESS[SET_BITS + 4:5]] && (WAY0_TAG[PREFETCH_LINE_ADDRESS[SET_BITS + 4:5]] == PREFETCH_LINE_ADDRESS[31:SET_BITS + 5])) || (WAY1_VALID[PREFETCH_LINE_ADDRESS[SET_BITS + 4:5]] && (WAY1_TAG[PREFETCH_LINE_ADDRESS[SET_BITS + 4:5]] == PREFETCH_LINE_ADDRESS[31:SET_BITS + 5]));
	assign REFILL_SET = REFILL_LINE_ADDRESS[SET_BITS + 4:5];
	assign REFILL_VICTIM_WAY = (!WAY0_VALID[REFILL_SET] ? 1'b0 : (!WAY1_VALID[REFILL_SET] ? 1'b1 : LEAST_RECENTLY_USED[REFILL_SET]));
	assign INSTALL = (REFILL_BUSY && (REFILL_CYCLES_LEFT == 6'd1)) && !(|WRITE_MASK);
	assign STORE_HIT = |WRITE_MASK && LINE_PRESENT;
	assign REFILL_ADDRESS = REFILL_LINE_ADDRESS;
	always @(posedge clk)
		if (reset) begin
			WAY0_VALID <= 1'sb0;
			WAY1_VALID <= 1'sb0;
			LEAST_RECENTLY_USED <= 1'sb0;
			REFILL_BUSY <= 1'b0;
			REFILL_CYCLES_LEFT <= 6'd0;
			REFILL_LINE_ADDRESS <= 64'd0;
			REFILL_IS_DEMAND <= 1'b0;
			PREFETCH_PENDING <= 1'b0;
			PREFETCH_LINE_ADDRESS <= 64'd0;
		end
		else if (!FREEZE) begin
			if ((LOAD_REQUEST || |WRITE_MASK) && LINE_PRESENT)
				LEAST_RECENTLY_USED[SET] <= HIT_WAY0;
			if (!REFILL_BUSY) begin
				if (LOAD_REQUEST && !LINE_PRESENT) begin
					REFILL_BUSY <= 1'b1;
					REFILL_CYCLES_LEFT <= MISS_LATENCY[5:0];
					REFILL_LINE_ADDRESS <= {ADDRESS[63:5], 5'b00000};
					REFILL_IS_DEMAND <= 1'b1;
				end
				else if (PREFETCH_PENDING) begin
					PREFETCH_PENDING <= 1'b0;
					if (!PREFETCH_PRESENT) begin
						REFILL_BUSY <= 1'b1;
						REFILL_CYCLES_LEFT <= MISS_LATENCY[5:0];
						REFILL_LINE_ADDRESS <= PREFETCH_LINE_ADDRESS;
						REFILL_IS_DEMAND <= 1'b0;
					end
				end
			end
			else if (INSTALL) begin
				REFILL_BUSY <= 1'b0;
				if (REFILL_VICTIM_WAY)
					WAY1_VALID[REFILL_SET] <= 1'b1;
				else
					WAY0_VALID[REFILL_SET] <= 1'b1;
				LEAST_RECENTLY_USED[REFILL_SET] <= !REFILL_VICTIM_WAY;
				if (REFILL_IS_DEMAND) begin
					PREFETCH_PENDING <= 1'b1;
					PREFETCH_LINE_ADDRESS <= REFILL_LINE_ADDRESS + 64'd32;
				end
			end
			else if (REFILL_CYCLES_LEFT != 6'd1)
				REFILL_CYCLES_LEFT <= REFILL_CYCLES_LEFT - 6'd1;
		end
	reg [SET_BITS - 1:0] DATA_WRITE_SET;
	reg [255:0] DATA_WRITE_LINE;
	reg [31:0] WAY0_BYTE_ENABLES;
	reg [31:0] WAY1_BYTE_ENABLES;
	reg [31:0] STORE_BYTE_ENABLES;
	always @(*) begin
		if (_sv2v_0)
			;
		STORE_BYTE_ENABLES = 32'd0;
		STORE_BYTE_ENABLES[8 * ADDRESS[4:3]+:8] = WRITE_MASK;
		DATA_WRITE_SET = (INSTALL ? REFILL_SET : SET);
		DATA_WRITE_LINE = (INSTALL ? REFILL_LINE : {4 {WRITE_DATA}});
		WAY0_BYTE_ENABLES = (INSTALL ? {32 {!REFILL_VICTIM_WAY}} : (STORE_HIT && HIT_WAY0 ? STORE_BYTE_ENABLES : 32'd0));
		WAY1_BYTE_ENABLES = (INSTALL ? {32 {REFILL_VICTIM_WAY}} : (STORE_HIT && HIT_WAY1 ? STORE_BYTE_ENABLES : 32'd0));
	end
	always @(posedge clk)
		if (!reset && !FREEZE) begin
			if (INSTALL) begin
				if (REFILL_VICTIM_WAY)
					WAY1_TAG[REFILL_SET] <= REFILL_LINE_ADDRESS[31:SET_BITS + 5];
				else
					WAY0_TAG[REFILL_SET] <= REFILL_LINE_ADDRESS[31:SET_BITS + 5];
			end
			begin : sv2v_autoblock_1
				reg signed [31:0] BYTE_LANE;
				for (BYTE_LANE = 0; BYTE_LANE < 32; BYTE_LANE = BYTE_LANE + 1)
					begin
						if (WAY0_BYTE_ENABLES[BYTE_LANE])
							WAY0_DATA[DATA_WRITE_SET][8 * BYTE_LANE+:8] <= DATA_WRITE_LINE[8 * BYTE_LANE+:8];
						if (WAY1_BYTE_ENABLES[BYTE_LANE])
							WAY1_DATA[DATA_WRITE_SET][8 * BYTE_LANE+:8] <= DATA_WRITE_LINE[8 * BYTE_LANE+:8];
					end
			end
		end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module Riscv64 (
	clk,
	reset,
	BRANCH_PREDICTION_ENABLE,
	TIMER_INTERRUPT_LINE,
	EXTERNAL_INTERRUPT_LINE,
	RESET_VECTOR,
	dcache_addr,
	icache_addr,
	dcache_we,
	dcache_din,
	dcache_dout,
	icache_dout,
	icache_hit,
	dcache_re,
	dcache_hit,
	csr,
	HALTED,
	DEBUG_REGISTER_ADDRESS,
	DEBUG_REGISTER_DATA,
	TRACE_VALID,
	TRACE_FETCH1_PC,
	TRACE_FETCH2_PC,
	TRACE_DECODE_PC,
	TRACE_EXECUTE_PC,
	TRACE_MEMORY_PC,
	TRACE_WRITEBACK_PC,
	TRACE_LOAD_STALL,
	TRACE_FLUSH,
	TRACE_REDIRECT,
	TRACE_MULTIPLY_DIVIDE_STALL,
	TRACE_INSTRUCTION_MISS,
	TRACE_DATA_MISS
);
	reg _sv2v_0;
	parameter signed [31:0] GSHARE_HISTORY_BITS = 6;
	parameter [0:0] BTB_ENABLE = 1'b1;
	parameter [0:0] RAS_ENABLE = 1'b1;
	parameter [0:0] PRECISE_LOAD_STALL = 1'b1;
	parameter [0:0] ITERATIVE_MULTIPLY_DIVIDE = 1'b1;
	parameter [0:0] TOURNAMENT_PREDICTOR = 1'b1;
	input wire clk;
	input wire reset;
	input wire BRANCH_PREDICTION_ENABLE;
	input wire TIMER_INTERRUPT_LINE;
	input wire EXTERNAL_INTERRUPT_LINE;
	input wire [63:0] RESET_VECTOR;
	output wire [63:0] dcache_addr;
	output wire [63:0] icache_addr;
	output wire [7:0] dcache_we;
	output wire [63:0] dcache_din;
	input wire [63:0] dcache_dout;
	input wire [31:0] icache_dout;
	input wire icache_hit;
	output wire dcache_re;
	input wire dcache_hit;
	output wire [63:0] csr;
	output reg HALTED;
	input wire [4:0] DEBUG_REGISTER_ADDRESS;
	output wire [63:0] DEBUG_REGISTER_DATA;
	output wire [5:0] TRACE_VALID;
	output wire [63:0] TRACE_FETCH1_PC;
	output wire [63:0] TRACE_FETCH2_PC;
	output wire [63:0] TRACE_DECODE_PC;
	output wire [63:0] TRACE_EXECUTE_PC;
	output wire [63:0] TRACE_MEMORY_PC;
	output wire [63:0] TRACE_WRITEBACK_PC;
	output wire TRACE_LOAD_STALL;
	output wire TRACE_FLUSH;
	output wire TRACE_REDIRECT;
	output wire TRACE_MULTIPLY_DIVIDE_STALL;
	output wire TRACE_INSTRUCTION_MISS;
	output wire TRACE_DATA_MISS;
	wire LOAD_STALL;
	wire FLUSH_FETCH1_FETCH2_DECODE;
	wire INTERRUPT_REQUEST;
	wire INTERRUPT_IS_EXTERNAL;
	wire DECODE_TAKES_INTERRUPT;
	wire ADVANCE_FRONT_END;
	wire FRONT_END_NOT_STALLED;
	wire MULTIPLY_DIVIDE_STALL;
	wire DATA_CACHE_STALL;
	wire HALT_NOW;
	wire FREEZE;
	reg [63:0] FETCH1_PC;
	wire [63:0] FETCH1_PC_ADD_4;
	wire FETCH1_INCREMENT_CARRY_UNUSED;
	ParallelPrefixAdder #(.WIDTH(64)) fetch1_incrementer(
		.A(FETCH1_PC),
		.B(64'd4),
		.CARRY_IN(1'b0),
		.SUM(FETCH1_PC_ADD_4),
		.CARRY_OUT(FETCH1_INCREMENT_CARRY_UNUSED)
	);
	assign icache_addr = FETCH1_PC;
	wire FETCH1_PREDICTED_BRANCH_TAKEN;
	wire [GSHARE_HISTORY_BITS - 1:0] FETCH1_GSHARE_INDEX;
	wire [GSHARE_HISTORY_BITS - 1:0] GLOBAL_HISTORY;
	reg EXECUTE_VALID;
	wire EXECUTE_UPDATE_BRANCH_PREDICTOR;
	wire EXECUTE_BRANCH_WAS_ACTUALLY_TAKEN;
	wire EXECUTE_PREDICTION_WAS_WRONG;
	reg [GSHARE_HISTORY_BITS - 1:0] EXECUTE_GSHARE_INDEX;
	reg [GSHARE_HISTORY_BITS - 1:0] EXECUTE_GLOBAL_HISTORY_CHECKPOINT;
	wire [GSHARE_HISTORY_BITS - 1:0] EXECUTE_RESTORED_GLOBAL_HISTORY;
	reg EXECUTE_IS_A_BRANCH_INSTRUCTION;
	wire BTB_HIT;
	wire BTB_HIT_IS_JAL;
	wire [63:0] BTB_PREDICTED_TARGET;
	wire FETCH1_BTB_REDIRECT;
	wire [63:0] FETCH1_NEXT_PC;
	wire EXECUTE_BTB_UPDATE;
	reg [63:0] EXECUTE_PC;
	reg [63:0] EXECUTE_PC_TARGET;
	reg EXECUTE_IS_A_JAL_INSTRUCTION;
	wire EXECUTE_BRANCH_TAKEN;
	BranchTargetBuffer #(.ENTRIES(16)) branch_target_buffer(
		.clk(clk),
		.reset(reset),
		.FETCH_PC(FETCH1_PC),
		.HIT(BTB_HIT),
		.HIT_IS_JAL(BTB_HIT_IS_JAL),
		.PREDICTED_TARGET(BTB_PREDICTED_TARGET),
		.UPDATE(EXECUTE_BTB_UPDATE),
		.UPDATE_PC(EXECUTE_PC),
		.UPDATE_TARGET(EXECUTE_PC_TARGET),
		.UPDATE_IS_JAL(EXECUTE_IS_A_JAL_INSTRUCTION)
	);
	assign FETCH1_BTB_REDIRECT = ((BTB_ENABLE && icache_hit) && BTB_HIT) && (BTB_HIT_IS_JAL || FETCH1_PREDICTED_BRANCH_TAKEN);
	assign FETCH1_NEXT_PC = (!icache_hit ? FETCH1_PC : (FETCH1_BTB_REDIRECT ? BTB_PREDICTED_TARGET : FETCH1_PC_ADD_4));
	reg [63:0] FETCH2_PC;
	reg FETCH2_VALID;
	reg [31:0] FETCH2_INSTRUCTION;
	wire [6:0] FETCH2_OPCODE;
	wire FETCH2_IS_A_BRANCH_INSTRUCTION;
	wire FETCH2_IS_A_JAL_INSTRUCTION;
	reg FETCH2_PREDICTED_BRANCH_TAKEN;
	reg [GSHARE_HISTORY_BITS - 1:0] FETCH2_GSHARE_INDEX;
	reg FETCH2_BTB_REDIRECTED;
	reg [63:0] FETCH2_PC_ADD_4;
	assign FETCH2_OPCODE = FETCH2_INSTRUCTION[6:0];
	localparam [6:0] opcode_pkg_OPC_BRANCH = 7'b1100011;
	assign FETCH2_IS_A_BRANCH_INSTRUCTION = FETCH2_OPCODE == opcode_pkg_OPC_BRANCH;
	localparam [6:0] opcode_pkg_OPC_JAL = 7'b1101111;
	assign FETCH2_IS_A_JAL_INSTRUCTION = FETCH2_OPCODE == opcode_pkg_OPC_JAL;
	wire [63:0] FETCH2_BRANCH_IMMEDIATE;
	wire [63:0] FETCH2_JAL_IMMEDIATE;
	wire [63:0] FETCH2_IMMEDIATE;
	wire [63:0] FETCH2_PC_TARGET;
	assign FETCH2_BRANCH_IMMEDIATE = {{51 {FETCH2_INSTRUCTION[31]}}, FETCH2_INSTRUCTION[31], FETCH2_INSTRUCTION[7], FETCH2_INSTRUCTION[30:25], FETCH2_INSTRUCTION[11:8], 1'b0};
	assign FETCH2_JAL_IMMEDIATE = {{43 {FETCH2_INSTRUCTION[31]}}, FETCH2_INSTRUCTION[31], FETCH2_INSTRUCTION[19:12], FETCH2_INSTRUCTION[20], FETCH2_INSTRUCTION[30:21], 1'b0};
	assign FETCH2_IMMEDIATE = (FETCH2_IS_A_JAL_INSTRUCTION ? FETCH2_JAL_IMMEDIATE : FETCH2_BRANCH_IMMEDIATE);
	wire FETCH2_TARGET_CARRY_UNUSED;
	ParallelPrefixAdder #(.WIDTH(64)) fetch2_target_adder(
		.A(FETCH2_PC),
		.B(FETCH2_IMMEDIATE),
		.CARRY_IN(1'b0),
		.SUM(FETCH2_PC_TARGET),
		.CARRY_OUT(FETCH2_TARGET_CARRY_UNUSED)
	);
	wire FETCH2_IS_A_JALR_INSTRUCTION;
	wire FETCH2_IS_A_CALL;
	wire FETCH2_IS_A_RETURN;
	wire FETCH2_RETURN_PREDICTED;
	wire [63:0] RETURN_ADDRESS_STACK_TOP;
	localparam signed [31:0] RAS_POINTER_BITS = 3;
	wire [2:0] RETURN_ADDRESS_STACK_POINTER;
	reg [2:0] EXECUTE_RAS_CHECKPOINT;
	reg EXECUTE_IS_A_CALL;
	reg EXECUTE_IS_A_RETURN;
	localparam [6:0] opcode_pkg_OPC_JALR = 7'b1100111;
	assign FETCH2_IS_A_JALR_INSTRUCTION = FETCH2_OPCODE == opcode_pkg_OPC_JALR;
	assign FETCH2_IS_A_CALL = (FETCH2_IS_A_JAL_INSTRUCTION || FETCH2_IS_A_JALR_INSTRUCTION) && ((FETCH2_INSTRUCTION[11:7] == 5'd1) || (FETCH2_INSTRUCTION[11:7] == 5'd5));
	assign FETCH2_IS_A_RETURN = ((FETCH2_IS_A_JALR_INSTRUCTION && (FETCH2_INSTRUCTION[11:7] == 5'd0)) && ((FETCH2_INSTRUCTION[19:15] == 5'd1) || (FETCH2_INSTRUCTION[19:15] == 5'd5))) && (FETCH2_INSTRUCTION[31:20] == 12'd0);
	assign FETCH2_RETURN_PREDICTED = RAS_ENABLE && FETCH2_IS_A_RETURN;
	ReturnAddressStack #(.DEPTH(8)) return_address_stack(
		.clk(clk),
		.reset(reset),
		.TOP_ADDRESS(RETURN_ADDRESS_STACK_TOP),
		.POINTER(RETURN_ADDRESS_STACK_POINTER),
		.PUSH((((RAS_ENABLE && !FREEZE) && FRONT_END_NOT_STALLED) && FETCH2_VALID) && FETCH2_IS_A_CALL),
		.POP((((RAS_ENABLE && !FREEZE) && FRONT_END_NOT_STALLED) && FETCH2_VALID) && FETCH2_IS_A_RETURN),
		.PUSH_ADDRESS(FETCH2_PC_ADD_4),
		.RESTORE((RAS_ENABLE && !FREEZE) && FLUSH_FETCH1_FETCH2_DECODE),
		.RESTORE_POINTER((EXECUTE_RAS_CHECKPOINT + {{2 {1'b0}}, EXECUTE_IS_A_CALL}) - {{2 {1'b0}}, EXECUTE_IS_A_RETURN})
	);
	wire FETCH2_BRANCHED;
	wire FETCH2_BRANCH_OFF_OR_CONTINUE;
	wire [63:0] FETCH2_REDIRECT_TARGET;
	wire [63:0] FETCH2_PREDICTED_NEXT_PC;
	assign FETCH2_BRANCHED = FETCH2_IS_A_BRANCH_INSTRUCTION && FETCH2_PREDICTED_BRANCH_TAKEN;
	assign FETCH2_BRANCH_OFF_OR_CONTINUE = (FETCH2_VALID && ((FETCH2_BRANCHED || FETCH2_IS_A_JAL_INSTRUCTION) || FETCH2_RETURN_PREDICTED)) && !FETCH2_BTB_REDIRECTED;
	assign FETCH2_REDIRECT_TARGET = (FETCH2_RETURN_PREDICTED ? RETURN_ADDRESS_STACK_TOP : FETCH2_PC_TARGET);
	assign FETCH2_PREDICTED_NEXT_PC = (FETCH2_BRANCH_OFF_OR_CONTINUE ? FETCH2_REDIRECT_TARGET : FETCH1_NEXT_PC);
	wire FETCH1_GSHARE_PREDICTED_TAKEN;
	wire FETCH1_BHT_PREDICTED_TAKEN;
	wire FETCH1_CHOOSE_GSHARE;
	reg FETCH2_GSHARE_PREDICTED_TAKEN;
	reg FETCH2_BHT_PREDICTED_TAKEN;
	reg DECODE_GSHARE_PREDICTED_TAKEN;
	reg DECODE_BHT_PREDICTED_TAKEN;
	reg EXECUTE_GSHARE_PREDICTED_TAKEN;
	reg EXECUTE_BHT_PREDICTED_TAKEN;
	TournamentChooser #(.INDEX_BITS(7)) tournament_chooser(
		.clk(clk),
		.reset(reset),
		.ENABLE(BRANCH_PREDICTION_ENABLE),
		.FETCH_PC(FETCH1_PC),
		.BHT_PREDICTED_TAKEN(FETCH1_BHT_PREDICTED_TAKEN),
		.CHOOSE_GSHARE(FETCH1_CHOOSE_GSHARE),
		.UPDATE(((TOURNAMENT_PREDICTOR && !FREEZE) && EXECUTE_VALID) && EXECUTE_UPDATE_BRANCH_PREDICTOR),
		.UPDATE_PC(EXECUTE_PC),
		.ACTUAL_BRANCH_TAKEN(EXECUTE_BRANCH_WAS_ACTUALLY_TAKEN),
		.BHT_WAS_TAKEN(EXECUTE_BHT_PREDICTED_TAKEN),
		.GSHARE_WAS_TAKEN(EXECUTE_GSHARE_PREDICTED_TAKEN)
	);
	assign FETCH1_PREDICTED_BRANCH_TAKEN = (TOURNAMENT_PREDICTOR ? (FETCH1_CHOOSE_GSHARE ? FETCH1_GSHARE_PREDICTED_TAKEN : FETCH1_BHT_PREDICTED_TAKEN) : FETCH1_GSHARE_PREDICTED_TAKEN);
	GSharePredictor #(.HISTORY_BITS(GSHARE_HISTORY_BITS)) gshare_branch_predictor(
		.clk(clk),
		.reset(reset),
		.ENABLE(BRANCH_PREDICTION_ENABLE),
		.FETCH_PC(FETCH1_PC),
		.FETCH_PREDICTED_TAKEN(FETCH1_GSHARE_PREDICTED_TAKEN),
		.FETCH_PREDICTION_INDEX(FETCH1_GSHARE_INDEX),
		.GLOBAL_HISTORY(GLOBAL_HISTORY),
		.SPECULATIVE_UPDATE(((!FREEZE && FRONT_END_NOT_STALLED) && FETCH2_VALID) && FETCH2_IS_A_BRANCH_INSTRUCTION),
		.SPECULATIVE_TAKEN(FETCH2_PREDICTED_BRANCH_TAKEN),
		.UPDATE_PREDICTION((!FREEZE && EXECUTE_VALID) && EXECUTE_UPDATE_BRANCH_PREDICTOR),
		.UPDATE_PREDICTION_INDEX(EXECUTE_GSHARE_INDEX),
		.ACTUAL_BRANCH_TAKEN(EXECUTE_BRANCH_WAS_ACTUALLY_TAKEN),
		.RESTORE_HISTORY(!FREEZE && FLUSH_FETCH1_FETCH2_DECODE),
		.RESTORE_HISTORY_VALUE(EXECUTE_RESTORED_GLOBAL_HISTORY)
	);
	reg [63:0] DECODE_PC;
	reg [31:0] DECODE_INSTRUCTION;
	reg DECODE_VALID;
	reg DECODE_PREDICTED_BRANCH_TAKEN;
	reg [GSHARE_HISTORY_BITS - 1:0] DECODE_GSHARE_INDEX;
	reg [GSHARE_HISTORY_BITS - 1:0] DECODE_GLOBAL_HISTORY_CHECKPOINT;
	reg [63:0] DECODE_PC_TARGET;
	reg [63:0] DECODE_PC_ADD_4;
	reg DECODE_RETURN_PREDICTED;
	reg DECODE_IS_A_CALL;
	reg DECODE_IS_A_RETURN;
	reg [2:0] DECODE_RAS_CHECKPOINT;
	wire DECODE_USES_REGISTER1;
	wire DECODE_USES_REGISTER2;
	wire DECODE_IS_AN_ECALL;
	wire DECODE_IS_AN_EBREAK;
	wire DECODE_IS_AN_MRET;
	wire [4:0] DECODE_REGISTER1_ADDRESS;
	wire [4:0] DECODE_REGISTER2_ADDRESS;
	wire [4:0] DECODE_DESTINATION_REGISTER_ADDRESS;
	wire [2:0] DECODE_FUNCT3;
	wire [11:0] DECODE_CSR_ADDRESS;
	wire [63:0] DECODE_REGISTER_FILE_REGISTER1_DATA;
	wire [63:0] DECODE_REGISTER_FILE_REGISTER2_DATA;
	reg [63:0] DECODE_FORWARDED_REGISTER1_DATA;
	reg [63:0] DECODE_FORWARDED_REGISTER2_DATA;
	wire [63:0] DECODE_IMMEDIATE;
	wire DECODE_REGISTER_WRITE_ENABLE;
	wire DECODE_MEMORY_READ_ENABLE;
	wire DECODE_MEMORY_WRITE_ENABLE;
	wire DECODE_CSR_WRITE_ENABLE;
	wire DECODE_CSR_WRITE_USING_IMMEDIATE;
	wire DECODE_ALU_INPUT_A_IS_PC;
	wire DECODE_ALU_INPUT_B_IS_IMMEDIATE;
	wire DECODE_ALU_IS_WORD_OPERATION;
	wire DECODE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION;
	wire DECODE_IS_A_BRANCH_INSTRUCTION;
	wire DECODE_IS_A_JAL_INSTRUCTION;
	wire DECODE_IS_A_JALR_INSTRUCTION;
	wire [2:0] DECODE_IMMEDIATE_TYPE_SELECT;
	wire [1:0] DECODE_WRITEBACK_SELECT;
	wire [5:0] DECODE_ALU_OPERATION;
	wire DECODE_ALU_OPERAND_A_ZERO_EXTEND;
	wire [1:0] DECODE_ALU_OPERAND_A_SHIFT;
	wire DECODE_ALU_OPERAND_B_INVERT;
	wire DECODE_ALU_OPERAND_B_SINGLE_BIT;
	assign DECODE_REGISTER1_ADDRESS = DECODE_INSTRUCTION[19:15];
	assign DECODE_REGISTER2_ADDRESS = DECODE_INSTRUCTION[24:20];
	assign DECODE_DESTINATION_REGISTER_ADDRESS = DECODE_INSTRUCTION[11:7];
	assign DECODE_FUNCT3 = DECODE_INSTRUCTION[14:12];
	assign DECODE_CSR_ADDRESS = DECODE_INSTRUCTION[31:20];
	reg [4:0] EXECUTE_DESTINATION_REGISTER_ADDRESS;
	reg EXECUTE_REGISTER_WRITE_ENABLE;
	reg EXECUTE_MEMORY_READ_ENABLE;
	reg [63:0] EXECUTE_FORWARD_DATA;
	reg [4:0] MEMORY_DESTINATION_REGISTER_ADDRESS;
	reg MEMORY_REGISTER_WRITE_ENABLE;
	reg MEMORY_VALID;
	wire [63:0] MEMORY_FORWARD_DATA;
	reg [4:0] WRITEBACK_DESTINATION_REGISTER_ADDRESS;
	reg WRITEBACK_REGISTER_WRITE_ENABLE;
	reg WRITEBACK_VALID;
	reg [63:0] WRITEBACK_DATA;
	RegisterFile register_file(
		.clk(clk),
		.reset(reset),
		.REGISTER_WRITE_ENABLE((!HALTED && WRITEBACK_VALID) && WRITEBACK_REGISTER_WRITE_ENABLE),
		.READ_ADDRESS1(DECODE_REGISTER1_ADDRESS),
		.READ_ADDRESS2(DECODE_REGISTER2_ADDRESS),
		.WRITE_ADDRESS(WRITEBACK_DESTINATION_REGISTER_ADDRESS),
		.WRITE_DATA(WRITEBACK_DATA),
		.READ_DATA1(DECODE_REGISTER_FILE_REGISTER1_DATA),
		.READ_DATA2(DECODE_REGISTER_FILE_REGISTER2_DATA),
		.DEBUG_READ_ADDRESS(DEBUG_REGISTER_ADDRESS),
		.DEBUG_READ_DATA(DEBUG_REGISTER_DATA)
	);
	reg EXECUTE_LATE_RESULT;
	always @(*) begin
		if (_sv2v_0)
			;
		if (DECODE_REGISTER1_ADDRESS == 5'd0)
			DECODE_FORWARDED_REGISTER1_DATA = 64'd0;
		else if (((((EXECUTE_VALID && EXECUTE_REGISTER_WRITE_ENABLE) && !EXECUTE_MEMORY_READ_ENABLE) && !EXECUTE_LATE_RESULT) && (EXECUTE_DESTINATION_REGISTER_ADDRESS != 5'd0)) && (EXECUTE_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER1_ADDRESS))
			DECODE_FORWARDED_REGISTER1_DATA = EXECUTE_FORWARD_DATA;
		else if (((MEMORY_VALID && MEMORY_REGISTER_WRITE_ENABLE) && (MEMORY_DESTINATION_REGISTER_ADDRESS != 5'd0)) && (MEMORY_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER1_ADDRESS))
			DECODE_FORWARDED_REGISTER1_DATA = MEMORY_FORWARD_DATA;
		else if (((WRITEBACK_VALID && WRITEBACK_REGISTER_WRITE_ENABLE) && (WRITEBACK_DESTINATION_REGISTER_ADDRESS != 5'd0)) && (WRITEBACK_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER1_ADDRESS))
			DECODE_FORWARDED_REGISTER1_DATA = WRITEBACK_DATA;
		else
			DECODE_FORWARDED_REGISTER1_DATA = DECODE_REGISTER_FILE_REGISTER1_DATA;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		if (DECODE_REGISTER2_ADDRESS == 5'd0)
			DECODE_FORWARDED_REGISTER2_DATA = 64'd0;
		else if (((((EXECUTE_VALID && EXECUTE_REGISTER_WRITE_ENABLE) && !EXECUTE_MEMORY_READ_ENABLE) && !EXECUTE_LATE_RESULT) && (EXECUTE_DESTINATION_REGISTER_ADDRESS != 5'd0)) && (EXECUTE_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER2_ADDRESS))
			DECODE_FORWARDED_REGISTER2_DATA = EXECUTE_FORWARD_DATA;
		else if (((MEMORY_VALID && MEMORY_REGISTER_WRITE_ENABLE) && (MEMORY_DESTINATION_REGISTER_ADDRESS != 5'd0)) && (MEMORY_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER2_ADDRESS))
			DECODE_FORWARDED_REGISTER2_DATA = MEMORY_FORWARD_DATA;
		else if (((WRITEBACK_VALID && WRITEBACK_REGISTER_WRITE_ENABLE) && (WRITEBACK_DESTINATION_REGISTER_ADDRESS != 5'd0)) && (WRITEBACK_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER2_ADDRESS))
			DECODE_FORWARDED_REGISTER2_DATA = WRITEBACK_DATA;
		else
			DECODE_FORWARDED_REGISTER2_DATA = DECODE_REGISTER_FILE_REGISTER2_DATA;
	end
	wire LOAD_HAZARD_REGISTER1;
	wire LOAD_HAZARD_REGISTER2;
	wire SINGLE_BIT_HAZARD;
	assign LOAD_HAZARD_REGISTER1 = (((EXECUTE_VALID && (EXECUTE_MEMORY_READ_ENABLE || EXECUTE_LATE_RESULT)) && (EXECUTE_DESTINATION_REGISTER_ADDRESS != 5'd0)) && (EXECUTE_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER1_ADDRESS)) && (!PRECISE_LOAD_STALL || DECODE_USES_REGISTER1);
	assign LOAD_HAZARD_REGISTER2 = (((EXECUTE_VALID && (EXECUTE_MEMORY_READ_ENABLE || EXECUTE_LATE_RESULT)) && (EXECUTE_DESTINATION_REGISTER_ADDRESS != 5'd0)) && (EXECUTE_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER2_ADDRESS)) && (!PRECISE_LOAD_STALL || DECODE_USES_REGISTER2);
	assign LOAD_STALL = DECODE_VALID && ((LOAD_HAZARD_REGISTER1 || LOAD_HAZARD_REGISTER2) || SINGLE_BIT_HAZARD);
	ControlUnit control_unit(
		.INSTRUCTION(DECODE_INSTRUCTION),
		.REGISTER_WRITE_ENABLE(DECODE_REGISTER_WRITE_ENABLE),
		.MEMORY_READ_ENABLE(DECODE_MEMORY_READ_ENABLE),
		.MEMORY_WRITE_ENABLE(DECODE_MEMORY_WRITE_ENABLE),
		.CSR_WRITE_USING_IMMEDIATE(DECODE_CSR_WRITE_USING_IMMEDIATE),
		.CSR_WRITE_ENABLE(DECODE_CSR_WRITE_ENABLE),
		.ALU_INPUT_A_IS_PC(DECODE_ALU_INPUT_A_IS_PC),
		.ALU_INPUT_B_IS_IMMEDIATE(DECODE_ALU_INPUT_B_IS_IMMEDIATE),
		.ALU_IS_WORD_OPERATION(DECODE_ALU_IS_WORD_OPERATION),
		.IS_A_MULTIPLY_DIVIDE_INSTRUCTION(DECODE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION),
		.IS_A_BRANCH_INSTRUCTION(DECODE_IS_A_BRANCH_INSTRUCTION),
		.IS_A_JAL_INSTRUCTION(DECODE_IS_A_JAL_INSTRUCTION),
		.IS_A_JALR_INSTRUCTION(DECODE_IS_A_JALR_INSTRUCTION),
		.IS_AN_ECALL(DECODE_IS_AN_ECALL),
		.IS_AN_EBREAK(DECODE_IS_AN_EBREAK),
		.IS_AN_MRET(DECODE_IS_AN_MRET),
		.USES_REGISTER1(DECODE_USES_REGISTER1),
		.USES_REGISTER2(DECODE_USES_REGISTER2),
		.IMMEDIATE_TYPE_SELECT(DECODE_IMMEDIATE_TYPE_SELECT),
		.WRITEBACK_SELECT(DECODE_WRITEBACK_SELECT),
		.ALU_OPERATION(DECODE_ALU_OPERATION),
		.ALU_OPERAND_A_ZERO_EXTEND(DECODE_ALU_OPERAND_A_ZERO_EXTEND),
		.ALU_OPERAND_A_SHIFT(DECODE_ALU_OPERAND_A_SHIFT),
		.ALU_OPERAND_B_INVERT(DECODE_ALU_OPERAND_B_INVERT),
		.ALU_OPERAND_B_SINGLE_BIT(DECODE_ALU_OPERAND_B_SINGLE_BIT)
	);
	wire DECODE_REGISTER1_FROM_EXECUTE;
	wire DECODE_REGISTER2_FROM_EXECUTE;
	assign DECODE_REGISTER1_FROM_EXECUTE = (((((DECODE_REGISTER1_ADDRESS != 5'd0) && EXECUTE_VALID) && EXECUTE_REGISTER_WRITE_ENABLE) && !EXECUTE_MEMORY_READ_ENABLE) && !EXECUTE_LATE_RESULT) && (EXECUTE_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER1_ADDRESS);
	assign DECODE_REGISTER2_FROM_EXECUTE = (((((DECODE_REGISTER2_ADDRESS != 5'd0) && EXECUTE_VALID) && EXECUTE_REGISTER_WRITE_ENABLE) && !EXECUTE_MEMORY_READ_ENABLE) && !EXECUTE_LATE_RESULT) && (EXECUTE_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER2_ADDRESS);
	reg [63:0] DECODE_EARLY_REGISTER1_DATA;
	reg [63:0] DECODE_EARLY_REGISTER2_DATA;
	always @(*) begin
		if (_sv2v_0)
			;
		if (DECODE_REGISTER1_ADDRESS == 5'd0)
			DECODE_EARLY_REGISTER1_DATA = 64'd0;
		else if ((MEMORY_VALID && MEMORY_REGISTER_WRITE_ENABLE) && (MEMORY_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER1_ADDRESS))
			DECODE_EARLY_REGISTER1_DATA = MEMORY_FORWARD_DATA;
		else if ((WRITEBACK_VALID && WRITEBACK_REGISTER_WRITE_ENABLE) && (WRITEBACK_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER1_ADDRESS))
			DECODE_EARLY_REGISTER1_DATA = WRITEBACK_DATA;
		else
			DECODE_EARLY_REGISTER1_DATA = DECODE_REGISTER_FILE_REGISTER1_DATA;
		if (DECODE_REGISTER2_ADDRESS == 5'd0)
			DECODE_EARLY_REGISTER2_DATA = 64'd0;
		else if ((MEMORY_VALID && MEMORY_REGISTER_WRITE_ENABLE) && (MEMORY_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER2_ADDRESS))
			DECODE_EARLY_REGISTER2_DATA = MEMORY_FORWARD_DATA;
		else if ((WRITEBACK_VALID && WRITEBACK_REGISTER_WRITE_ENABLE) && (WRITEBACK_DESTINATION_REGISTER_ADDRESS == DECODE_REGISTER2_ADDRESS))
			DECODE_EARLY_REGISTER2_DATA = WRITEBACK_DATA;
		else
			DECODE_EARLY_REGISTER2_DATA = DECODE_REGISTER_FILE_REGISTER2_DATA;
	end
	function automatic [63:0] prepare_operand_a;
		input reg [63:0] value;
		input reg zero_extend;
		input reg [1:0] shift;
		reg [63:0] extended;
		begin
			extended = (zero_extend ? {32'd0, value[31:0]} : value);
			prepare_operand_a = extended << shift;
		end
	endfunction
	function automatic [63:0] prepare_operand_b;
		input reg [63:0] value;
		input reg invert;
		input reg single_bit;
		reg [63:0] chosen;
		begin
			chosen = (single_bit ? 64'd1 << value[5:0] : value);
			prepare_operand_b = (invert ? ~chosen : chosen);
		end
	endfunction
	wire [63:0] DECODE_EARLY_ALU_INPUT_A;
	wire [63:0] DECODE_EARLY_ALU_INPUT_B;
	wire [63:0] DECODE_LATE_ALU_INPUT_A;
	wire [63:0] DECODE_LATE_ALU_INPUT_B;
	wire [63:0] DECODE_ALU_INPUT_A;
	wire [63:0] DECODE_ALU_INPUT_B;
	assign DECODE_EARLY_ALU_INPUT_A = (DECODE_ALU_INPUT_A_IS_PC ? DECODE_PC : prepare_operand_a(DECODE_EARLY_REGISTER1_DATA, DECODE_ALU_OPERAND_A_ZERO_EXTEND, DECODE_ALU_OPERAND_A_SHIFT));
	assign DECODE_EARLY_ALU_INPUT_B = prepare_operand_b((DECODE_ALU_INPUT_B_IS_IMMEDIATE ? DECODE_IMMEDIATE : DECODE_EARLY_REGISTER2_DATA), DECODE_ALU_OPERAND_B_INVERT, DECODE_ALU_OPERAND_B_SINGLE_BIT);
	assign DECODE_LATE_ALU_INPUT_A = prepare_operand_a(EXECUTE_FORWARD_DATA, DECODE_ALU_OPERAND_A_ZERO_EXTEND, DECODE_ALU_OPERAND_A_SHIFT);
	assign DECODE_LATE_ALU_INPUT_B = (DECODE_ALU_OPERAND_B_INVERT ? ~EXECUTE_FORWARD_DATA : EXECUTE_FORWARD_DATA);
	assign SINGLE_BIT_HAZARD = (DECODE_ALU_OPERAND_B_SINGLE_BIT && !DECODE_ALU_INPUT_B_IS_IMMEDIATE) && DECODE_REGISTER2_FROM_EXECUTE;
	assign DECODE_ALU_INPUT_A = (DECODE_REGISTER1_FROM_EXECUTE && !DECODE_ALU_INPUT_A_IS_PC ? DECODE_LATE_ALU_INPUT_A : DECODE_EARLY_ALU_INPUT_A);
	assign DECODE_ALU_INPUT_B = (DECODE_REGISTER2_FROM_EXECUTE && !DECODE_ALU_INPUT_B_IS_IMMEDIATE ? DECODE_LATE_ALU_INPUT_B : DECODE_EARLY_ALU_INPUT_B);
	ImmediateGenerator immediate_generator(
		.INSTRUCTION(DECODE_INSTRUCTION),
		.IMMEDIATE_TYPE_SELECT(DECODE_IMMEDIATE_TYPE_SELECT),
		.IMMEDIATE(DECODE_IMMEDIATE)
	);
	reg [31:0] EXECUTE_INSTRUCTION;
	reg [63:0] EXECUTE_REGISTER1_DATA;
	reg [63:0] EXECUTE_REGISTER2_DATA;
	reg [63:0] EXECUTE_IMMEDIATE;
	reg [2:0] EXECUTE_FUNCT3;
	reg [11:0] EXECUTE_CSR_ADDRESS;
	reg EXECUTE_MEMORY_WRITE_ENABLE;
	reg EXECUTE_CSR_WRITE_ENABLE;
	reg EXECUTE_CSR_WRITE_USING_IMMEDIATE;
	reg EXECUTE_ALU_INPUT_A_IS_PC;
	reg EXECUTE_ALU_INPUT_B_IS_IMMEDIATE;
	reg EXECUTE_ALU_IS_WORD_OPERATION;
	reg EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION;
	reg EXECUTE_IS_A_JALR_INSTRUCTION;
	reg EXECUTE_PREDICTED_BRANCH_TAKEN;
	reg EXECUTE_RETURN_PREDICTED;
	reg EXECUTE_IS_AN_ECALL;
	reg EXECUTE_IS_AN_EBREAK;
	reg EXECUTE_IS_AN_MRET;
	reg EXECUTE_IS_AN_INTERRUPT;
	reg EXECUTE_INTERRUPT_IS_EXTERNAL;
	wire EXECUTE_TAKES_TRAP;
	wire EXECUTE_RETURNS_FROM_TRAP;
	wire [63:0] TRAP_VECTOR;
	wire [63:0] EXCEPTION_PC;
	wire [63:0] EXECUTE_REDIRECT_PC;
	reg [1:0] EXECUTE_WRITEBACK_SELECT;
	reg [5:0] EXECUTE_ALU_OPERATION;
	reg EXECUTE_ALU_SUBTRACT;
	reg [2:0] EXECUTE_MULTIPLY_DIVIDE_PREDECODED;
	reg [63:0] EXECUTE_PC_ADD_4;
	reg [63:0] EXECUTE_ALU_INPUT_A;
	reg [63:0] EXECUTE_ALU_INPUT_B;
	wire [63:0] EXECUTE_ALU_OUTPUT;
	wire [63:0] EXECUTE_ALU_FAST_OUTPUT;
	wire [63:0] EXECUTE_FAST_RESULT;
	wire [63:0] EXECUTE_MULTIPLY_DIVIDE_OUTPUT;
	wire [63:0] EXECUTE_ALU_RESULT;
	wire [63:0] EXECUTE_JALR_TARGET;
	wire EXECUTE_FLUSH;
	wire [63:0] EXECUTE_ADJUST_NEXT_PC;
	wire [63:0] EXECUTE_CSR_READ_DATA;
	wire [63:0] EXECUTE_CSR_WRITE_DATA;
	wire [7:0] EXECUTE_STORE_MASK;
	wire [63:0] EXECUTE_STORE_DATA;
	wire EXECUTE_WRITES_TOHOST;
	ALU alu(
		.A(EXECUTE_ALU_INPUT_A),
		.B(EXECUTE_ALU_INPUT_B),
		.ALUop(EXECUTE_ALU_OPERATION),
		.SUBTRACT_MODE(EXECUTE_ALU_SUBTRACT),
		.ALU_IS_WORD_OPERATION(EXECUTE_ALU_IS_WORD_OPERATION),
		.LATE_RESULT(EXECUTE_LATE_RESULT),
		.ALUOutFast(EXECUTE_ALU_FAST_OUTPUT),
		.ALUOut(EXECUTE_ALU_OUTPUT)
	);
	wire MULTIPLY_DIVIDE_READY;
	generate
		if (ITERATIVE_MULTIPLY_DIVIDE) begin : iterative_m_extension
			IterativeMultiplyDivideUnit multiply_divide_unit(
				.clk(clk),
				.reset(reset),
				.FREEZE(FREEZE),
				.REQUEST(EXECUTE_VALID && EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION),
				.A(EXECUTE_REGISTER1_DATA),
				.B(EXECUTE_REGISTER2_DATA),
				.MULTIPLY_DIVIDE_OPERATION(EXECUTE_ALU_OPERATION),
				.IS_WORD_OPERATION(EXECUTE_ALU_IS_WORD_OPERATION),
				.PREDECODED(EXECUTE_MULTIPLY_DIVIDE_PREDECODED),
				.READY(MULTIPLY_DIVIDE_READY),
				.MULTIPLY_DIVIDE_RESULT(EXECUTE_MULTIPLY_DIVIDE_OUTPUT)
			);
		end
		else begin : single_cycle_m_extension
			MultiplyDivideUnit multiply_divide_unit(
				.A(EXECUTE_REGISTER1_DATA),
				.B(EXECUTE_REGISTER2_DATA),
				.MULTIPLY_DIVIDE_OPERATION(EXECUTE_ALU_OPERATION),
				.IS_WORD_OPERATION(EXECUTE_ALU_IS_WORD_OPERATION),
				.MULTIPLY_DIVIDE_RESULT(EXECUTE_MULTIPLY_DIVIDE_OUTPUT)
			);
			assign MULTIPLY_DIVIDE_READY = 1'b1;
		end
	endgenerate
	assign MULTIPLY_DIVIDE_STALL = (EXECUTE_VALID && EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION) && !MULTIPLY_DIVIDE_READY;
	assign EXECUTE_ALU_RESULT = (EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION ? EXECUTE_MULTIPLY_DIVIDE_OUTPUT : EXECUTE_ALU_OUTPUT);
	assign EXECUTE_FAST_RESULT = (EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION ? EXECUTE_MULTIPLY_DIVIDE_OUTPUT : EXECUTE_ALU_FAST_OUTPUT);
	assign EXECUTE_JALR_TARGET = {EXECUTE_ALU_FAST_OUTPUT[63:1], 1'b0};
	BranchComparator branch_comparator(
		.A(EXECUTE_REGISTER1_DATA),
		.B(EXECUTE_REGISTER2_DATA),
		.BRANCH_FUNCT3(EXECUTE_FUNCT3),
		.BRANCH_TAKEN(EXECUTE_BRANCH_TAKEN)
	);
	wire EXECUTE_RETURN_PREDICTION_CORRECT;
	assign EXECUTE_RETURN_PREDICTION_CORRECT = EXECUTE_RETURN_PREDICTED && ({EXECUTE_REGISTER1_DATA[63:1], 1'b0} == EXECUTE_PC_TARGET);
	BranchControl branch_control(
		.IS_A_BRANCH_INSTRUCTION(EXECUTE_IS_A_BRANCH_INSTRUCTION),
		.IS_A_JAL_INSTRUCTION(EXECUTE_IS_A_JAL_INSTRUCTION),
		.IS_A_JALR_INSTRUCTION(EXECUTE_IS_A_JALR_INSTRUCTION),
		.ACTUALLY_TAKEN_BRANCH(EXECUTE_BRANCH_TAKEN),
		.PREDICTED_BRANCH_TAKEN(EXECUTE_PREDICTED_BRANCH_TAKEN),
		.PC_ADD_4(EXECUTE_PC_ADD_4),
		.BRANCH_TARGET(EXECUTE_PC_TARGET),
		.JALR_TARGET(EXECUTE_JALR_TARGET),
		.JALR_PREDICTION_CORRECT(EXECUTE_RETURN_PREDICTION_CORRECT),
		.BRANCH_WAS_ACTUALLY_TAKEN(EXECUTE_BRANCH_WAS_ACTUALLY_TAKEN),
		.PREDICTION_WAS_WRONG(EXECUTE_PREDICTION_WAS_WRONG),
		.FLUSH(EXECUTE_FLUSH),
		.UPDATE_BRANCH_PREDICTOR(EXECUTE_UPDATE_BRANCH_PREDICTOR),
		.ADJUST_NEXT_PC(EXECUTE_ADJUST_NEXT_PC)
	);
	assign EXECUTE_TAKES_TRAP = EXECUTE_VALID && ((EXECUTE_IS_AN_ECALL || EXECUTE_IS_AN_EBREAK) || EXECUTE_IS_AN_INTERRUPT);
	assign EXECUTE_RETURNS_FROM_TRAP = EXECUTE_VALID && EXECUTE_IS_AN_MRET;
	assign EXECUTE_REDIRECT_PC = (EXECUTE_TAKES_TRAP ? TRAP_VECTOR : (EXECUTE_RETURNS_FROM_TRAP ? EXCEPTION_PC : EXECUTE_ADJUST_NEXT_PC));
	assign FLUSH_FETCH1_FETCH2_DECODE = EXECUTE_VALID && ((((EXECUTE_FLUSH || EXECUTE_IS_AN_ECALL) || EXECUTE_IS_AN_EBREAK) || EXECUTE_IS_AN_MRET) || EXECUTE_IS_AN_INTERRUPT);
	assign DECODE_TAKES_INTERRUPT = (INTERRUPT_REQUEST && DECODE_VALID) && !(EXECUTE_VALID && ((((EXECUTE_CSR_WRITE_ENABLE || EXECUTE_IS_AN_ECALL) || EXECUTE_IS_AN_EBREAK) || EXECUTE_IS_AN_MRET) || EXECUTE_IS_AN_INTERRUPT));
	assign dcache_re = EXECUTE_VALID && EXECUTE_MEMORY_READ_ENABLE;
	assign DATA_CACHE_STALL = dcache_re && !dcache_hit;
	assign FRONT_END_NOT_STALLED = (!DATA_CACHE_STALL && !LOAD_STALL) && !MULTIPLY_DIVIDE_STALL;
	assign ADVANCE_FRONT_END = !FLUSH_FETCH1_FETCH2_DECODE && FRONT_END_NOT_STALLED;
	assign EXECUTE_BTB_UPDATE = ((BTB_ENABLE && !FREEZE) && EXECUTE_VALID) && ((EXECUTE_IS_A_BRANCH_INSTRUCTION && EXECUTE_BRANCH_TAKEN) || EXECUTE_IS_A_JAL_INSTRUCTION);
	assign EXECUTE_RESTORED_GLOBAL_HISTORY = (EXECUTE_IS_A_BRANCH_INSTRUCTION ? {EXECUTE_GLOBAL_HISTORY_CHECKPOINT[GSHARE_HISTORY_BITS - 2:0], EXECUTE_BRANCH_WAS_ACTUALLY_TAKEN} : EXECUTE_GLOBAL_HISTORY_CHECKPOINT);
	wire [2:0] EXECUTE_STORE_BYTE_OFFSET;
	assign EXECUTE_STORE_BYTE_OFFSET = EXECUTE_REGISTER1_DATA[2:0] + EXECUTE_IMMEDIATE[2:0];
	StoreControl store_control(
		.STORE_FUNCT3(EXECUTE_FUNCT3),
		.MEMORY_ADDRESS({EXECUTE_FAST_RESULT[63:3], EXECUTE_STORE_BYTE_OFFSET}),
		.MEMORY_INFO(EXECUTE_REGISTER2_DATA),
		.WRITE_MASK_FOR_STORE(EXECUTE_STORE_MASK),
		.DATA_TO_STORE(EXECUTE_STORE_DATA)
	);
	assign EXECUTE_CSR_WRITE_DATA = (EXECUTE_CSR_WRITE_USING_IMMEDIATE ? {59'd0, EXECUTE_INSTRUCTION[19:15]} : EXECUTE_REGISTER1_DATA);
	localparam [11:0] const_pkg_CSR_TOHOST = 12'h51e;
	assign EXECUTE_WRITES_TOHOST = EXECUTE_CSR_WRITE_ENABLE && (EXECUTE_CSR_ADDRESS == const_pkg_CSR_TOHOST);
	localparam [63:0] const_pkg_CAUSE_BREAKPOINT = 64'd3;
	localparam [63:0] const_pkg_CAUSE_ENVIRONMENT_CALL = 64'd11;
	localparam [63:0] const_pkg_CAUSE_MACHINE_EXTERNAL_INTERRUPT = 64'h800000000000000b;
	localparam [63:0] const_pkg_CAUSE_MACHINE_TIMER_INTERRUPT = 64'h8000000000000007;
	CSRFile control_status_register_file(
		.clk(clk),
		.reset(reset),
		.CSR_WRITE_ENABLE((!FREEZE && EXECUTE_CSR_WRITE_ENABLE) && EXECUTE_VALID),
		.CSR_ADDRESS(EXECUTE_CSR_ADDRESS),
		.CSR_OPERATION(EXECUTE_FUNCT3),
		.CSR_WRITE_DATA(EXECUTE_CSR_WRITE_DATA),
		.INSTRUCTION_RETIRED(WRITEBACK_VALID),
		.PERFORMANCE_EVENTS({EXECUTE_VALID && EXECUTE_IS_AN_INTERRUPT, TRACE_DATA_MISS, TRACE_INSTRUCTION_MISS, TRACE_MULTIPLY_DIVIDE_STALL, TRACE_REDIRECT, TRACE_FLUSH, TRACE_LOAD_STALL}),
		.TAKE_TRAP(!FREEZE && EXECUTE_TAKES_TRAP),
		.TRAP_PC(EXECUTE_PC),
		.TRAP_CAUSE((EXECUTE_IS_AN_INTERRUPT ? (EXECUTE_INTERRUPT_IS_EXTERNAL ? const_pkg_CAUSE_MACHINE_EXTERNAL_INTERRUPT : const_pkg_CAUSE_MACHINE_TIMER_INTERRUPT) : (EXECUTE_IS_AN_EBREAK ? const_pkg_CAUSE_BREAKPOINT : const_pkg_CAUSE_ENVIRONMENT_CALL))),
		.TIMER_INTERRUPT_LINE(TIMER_INTERRUPT_LINE),
		.EXTERNAL_INTERRUPT_LINE(EXTERNAL_INTERRUPT_LINE),
		.INTERRUPT_REQUEST(INTERRUPT_REQUEST),
		.INTERRUPT_IS_EXTERNAL(INTERRUPT_IS_EXTERNAL),
		.RETURN_FROM_TRAP(!FREEZE && EXECUTE_RETURNS_FROM_TRAP),
		.TRAP_VECTOR(TRAP_VECTOR),
		.EXCEPTION_PC(EXCEPTION_PC),
		.CSR_READ_DATA(EXECUTE_CSR_READ_DATA),
		.TOHOST(csr)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (EXECUTE_WRITEBACK_SELECT)
			2'd0: EXECUTE_FORWARD_DATA = EXECUTE_FAST_RESULT;
			2'd2: EXECUTE_FORWARD_DATA = EXECUTE_PC_ADD_4;
			2'd3: EXECUTE_FORWARD_DATA = EXECUTE_CSR_READ_DATA;
			2'd1: EXECUTE_FORWARD_DATA = 64'd0;
			default: EXECUTE_FORWARD_DATA = EXECUTE_FAST_RESULT;
		endcase
	end
	assign dcache_addr = EXECUTE_FAST_RESULT;
	assign dcache_din = EXECUTE_STORE_DATA;
	assign dcache_we = ((!FREEZE && EXECUTE_VALID) && EXECUTE_MEMORY_WRITE_ENABLE ? EXECUTE_STORE_MASK : 8'b00000000);
	reg [63:0] MEMORY_PC;
	reg [2:0] MEMORY_FUNCT3;
	reg [63:0] MEMORY_ALU_RESULT;
	reg [63:0] MEMORY_PC_ADD_4;
	reg [63:0] MEMORY_CSR_READ_DATA;
	reg [1:0] MEMORY_WRITEBACK_SELECT;
	wire [63:0] MEMORY_LOAD_DATA;
	reg [63:0] MEMORY_DATA_CACHE_DATA;
	reg MEMORY_WRITES_TOHOST;
	wire MEMORY_REGISTER_WRITE_ENABLE_OUT;
	reg MEMORY_IS_POPULATION_COUNT;
	reg MEMORY_POPULATION_COUNT_WORD;
	wire [6:0] MEMORY_POPULATION;
	wire [63:0] MEMORY_RESULT;
	PopulationCountFinish population_count_finish(
		.QUARTER_COUNTS(MEMORY_ALU_RESULT[19:0]),
		.WORD(MEMORY_POPULATION_COUNT_WORD),
		.COUNT(MEMORY_POPULATION)
	);
	assign MEMORY_RESULT = (MEMORY_IS_POPULATION_COUNT ? {57'd0, MEMORY_POPULATION} : MEMORY_ALU_RESULT);
	LoadControl load_control(
		.LOAD_FUNCT3(MEMORY_FUNCT3),
		.MEMORY_ADDRESS(MEMORY_ALU_RESULT),
		.MEMORY_INFO(MEMORY_DATA_CACHE_DATA),
		.DATA_TO_LOAD(MEMORY_LOAD_DATA)
	);
	WriteControl write_control(
		.REGISTER_WRITE_ENABLE_INPUT(MEMORY_REGISTER_WRITE_ENABLE),
		.WRITEBACK_SELECT(MEMORY_WRITEBACK_SELECT),
		.ALU_RESULT(MEMORY_RESULT),
		.MEMORY_DATA(MEMORY_LOAD_DATA),
		.PC_ADD_4(MEMORY_PC_ADD_4),
		.CSR_DATA(MEMORY_CSR_READ_DATA),
		.REGISTER_WRITE_ENABLE_OUTPUT(MEMORY_REGISTER_WRITE_ENABLE_OUT),
		.WRITEBACK_DATA(MEMORY_FORWARD_DATA)
	);
	reg [63:0] WRITEBACK_PC;
	reg WRITEBACK_WRITES_TOHOST;
	assign HALT_NOW = ((!HALTED && WRITEBACK_VALID) && WRITEBACK_WRITES_TOHOST) && (csr != 64'd0);
	assign FREEZE = HALTED || HALT_NOW;
	localparam [2:0] opcode_pkg_FNC_ADD_SUB = 3'b000;
	localparam [6:0] opcode_pkg_OPC_ARI_ITYPE = 7'b0010011;
	localparam [31:0] const_pkg_INSTR_NOP = {17'h00000, opcode_pkg_FNC_ADD_SUB, 5'd0, opcode_pkg_OPC_ARI_ITYPE};
	always @(posedge clk)
		if (reset) begin
			FETCH1_PC <= RESET_VECTOR;
			HALTED <= 1'b0;
			FETCH2_VALID <= 1'b0;
			FETCH2_PC <= 64'd0;
			FETCH2_PC_ADD_4 <= 64'd4;
			FETCH2_INSTRUCTION <= const_pkg_INSTR_NOP;
			FETCH2_PREDICTED_BRANCH_TAKEN <= 1'b0;
			FETCH2_GSHARE_INDEX <= 1'sb0;
			FETCH2_BTB_REDIRECTED <= 1'b0;
			FETCH2_GSHARE_PREDICTED_TAKEN <= 1'b0;
			FETCH2_BHT_PREDICTED_TAKEN <= 1'b0;
			DECODE_GSHARE_PREDICTED_TAKEN <= 1'b0;
			DECODE_BHT_PREDICTED_TAKEN <= 1'b0;
			EXECUTE_GSHARE_PREDICTED_TAKEN <= 1'b0;
			EXECUTE_BHT_PREDICTED_TAKEN <= 1'b0;
			DECODE_VALID <= 1'b0;
			DECODE_PC <= 64'd0;
			DECODE_INSTRUCTION <= const_pkg_INSTR_NOP;
			DECODE_PREDICTED_BRANCH_TAKEN <= 1'b0;
			DECODE_GSHARE_INDEX <= 1'sb0;
			DECODE_GLOBAL_HISTORY_CHECKPOINT <= 1'sb0;
			DECODE_PC_TARGET <= 64'd0;
			DECODE_PC_ADD_4 <= 64'd0;
			DECODE_RETURN_PREDICTED <= 1'b0;
			DECODE_IS_A_CALL <= 1'b0;
			DECODE_IS_A_RETURN <= 1'b0;
			DECODE_RAS_CHECKPOINT <= 1'sb0;
			EXECUTE_VALID <= 1'b0;
			EXECUTE_PC <= 64'd0;
			EXECUTE_INSTRUCTION <= const_pkg_INSTR_NOP;
			EXECUTE_REGISTER1_DATA <= 64'd0;
			EXECUTE_ALU_INPUT_A <= 64'd0;
			EXECUTE_ALU_INPUT_B <= 64'd0;
			EXECUTE_REGISTER2_DATA <= 64'd0;
			EXECUTE_IMMEDIATE <= 64'd0;
			EXECUTE_DESTINATION_REGISTER_ADDRESS <= 5'd0;
			EXECUTE_FUNCT3 <= 3'd0;
			EXECUTE_CSR_ADDRESS <= 12'd0;
			EXECUTE_REGISTER_WRITE_ENABLE <= 1'b0;
			EXECUTE_MEMORY_READ_ENABLE <= 1'b0;
			EXECUTE_MEMORY_WRITE_ENABLE <= 1'b0;
			EXECUTE_CSR_WRITE_ENABLE <= 1'b0;
			EXECUTE_CSR_WRITE_USING_IMMEDIATE <= 1'b0;
			EXECUTE_ALU_INPUT_A_IS_PC <= 1'b0;
			EXECUTE_ALU_INPUT_B_IS_IMMEDIATE <= 1'b0;
			EXECUTE_ALU_IS_WORD_OPERATION <= 1'b0;
			EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION <= 1'b0;
			EXECUTE_IS_A_BRANCH_INSTRUCTION <= 1'b0;
			EXECUTE_IS_A_JAL_INSTRUCTION <= 1'b0;
			EXECUTE_IS_A_JALR_INSTRUCTION <= 1'b0;
			EXECUTE_PREDICTED_BRANCH_TAKEN <= 1'b0;
			EXECUTE_GSHARE_INDEX <= 1'sb0;
			EXECUTE_GLOBAL_HISTORY_CHECKPOINT <= 1'sb0;
			EXECUTE_WRITEBACK_SELECT <= 2'd0;
			EXECUTE_ALU_OPERATION <= 6'd63;
			EXECUTE_ALU_SUBTRACT <= 1'b0;
			EXECUTE_LATE_RESULT <= 1'b0;
			EXECUTE_MULTIPLY_DIVIDE_PREDECODED <= 3'b000;
			EXECUTE_PC_TARGET <= 64'd0;
			EXECUTE_PC_ADD_4 <= 64'd0;
			EXECUTE_RETURN_PREDICTED <= 1'b0;
			EXECUTE_IS_A_CALL <= 1'b0;
			EXECUTE_IS_A_RETURN <= 1'b0;
			EXECUTE_RAS_CHECKPOINT <= 1'sb0;
			EXECUTE_IS_AN_ECALL <= 1'b0;
			EXECUTE_IS_AN_EBREAK <= 1'b0;
			EXECUTE_IS_AN_MRET <= 1'b0;
			EXECUTE_IS_AN_INTERRUPT <= 1'b0;
			EXECUTE_INTERRUPT_IS_EXTERNAL <= 1'b0;
			MEMORY_VALID <= 1'b0;
			MEMORY_PC <= 64'd0;
			MEMORY_DESTINATION_REGISTER_ADDRESS <= 5'd0;
			MEMORY_FUNCT3 <= 3'd0;
			MEMORY_ALU_RESULT <= 64'd0;
			MEMORY_IS_POPULATION_COUNT <= 1'b0;
			MEMORY_POPULATION_COUNT_WORD <= 1'b0;
			MEMORY_PC_ADD_4 <= 64'd0;
			MEMORY_CSR_READ_DATA <= 64'd0;
			MEMORY_REGISTER_WRITE_ENABLE <= 1'b0;
			MEMORY_WRITEBACK_SELECT <= 2'd0;
			MEMORY_DATA_CACHE_DATA <= 64'd0;
			MEMORY_WRITES_TOHOST <= 1'b0;
			WRITEBACK_VALID <= 1'b0;
			WRITEBACK_PC <= 64'd0;
			WRITEBACK_DESTINATION_REGISTER_ADDRESS <= 5'd0;
			WRITEBACK_REGISTER_WRITE_ENABLE <= 1'b0;
			WRITEBACK_DATA <= 64'd0;
			WRITEBACK_WRITES_TOHOST <= 1'b0;
		end
		else if (HALTED)
			;
		else if (HALT_NOW)
			HALTED <= 1'b1;
		else begin
			MEMORY_VALID <= EXECUTE_VALID && !EXECUTE_IS_AN_INTERRUPT;
			MEMORY_PC <= EXECUTE_PC;
			MEMORY_DESTINATION_REGISTER_ADDRESS <= EXECUTE_DESTINATION_REGISTER_ADDRESS;
			MEMORY_FUNCT3 <= EXECUTE_FUNCT3;
			MEMORY_ALU_RESULT <= EXECUTE_ALU_RESULT;
			MEMORY_IS_POPULATION_COUNT <= !EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION && (EXECUTE_ALU_OPERATION == 6'd38);
			MEMORY_POPULATION_COUNT_WORD <= EXECUTE_ALU_IS_WORD_OPERATION;
			MEMORY_PC_ADD_4 <= EXECUTE_PC_ADD_4;
			MEMORY_CSR_READ_DATA <= EXECUTE_CSR_READ_DATA;
			MEMORY_REGISTER_WRITE_ENABLE <= EXECUTE_REGISTER_WRITE_ENABLE;
			MEMORY_WRITEBACK_SELECT <= EXECUTE_WRITEBACK_SELECT;
			MEMORY_DATA_CACHE_DATA <= dcache_dout;
			MEMORY_WRITES_TOHOST <= EXECUTE_VALID && EXECUTE_WRITES_TOHOST;
			WRITEBACK_VALID <= MEMORY_VALID;
			WRITEBACK_PC <= MEMORY_PC;
			WRITEBACK_DESTINATION_REGISTER_ADDRESS <= MEMORY_DESTINATION_REGISTER_ADDRESS;
			WRITEBACK_REGISTER_WRITE_ENABLE <= MEMORY_REGISTER_WRITE_ENABLE_OUT;
			WRITEBACK_DATA <= MEMORY_FORWARD_DATA;
			WRITEBACK_WRITES_TOHOST <= MEMORY_WRITES_TOHOST;
			if (!DATA_CACHE_STALL && !MULTIPLY_DIVIDE_STALL) begin
				EXECUTE_PC <= DECODE_PC;
				EXECUTE_REGISTER1_DATA <= DECODE_FORWARDED_REGISTER1_DATA;
				EXECUTE_ALU_INPUT_A <= DECODE_ALU_INPUT_A;
				EXECUTE_ALU_INPUT_B <= DECODE_ALU_INPUT_B;
				EXECUTE_REGISTER2_DATA <= DECODE_FORWARDED_REGISTER2_DATA;
				EXECUTE_IMMEDIATE <= DECODE_IMMEDIATE;
				EXECUTE_DESTINATION_REGISTER_ADDRESS <= DECODE_DESTINATION_REGISTER_ADDRESS;
				EXECUTE_FUNCT3 <= DECODE_FUNCT3;
				EXECUTE_CSR_ADDRESS <= DECODE_CSR_ADDRESS;
				EXECUTE_CSR_WRITE_USING_IMMEDIATE <= DECODE_CSR_WRITE_USING_IMMEDIATE;
				EXECUTE_ALU_INPUT_A_IS_PC <= DECODE_ALU_INPUT_A_IS_PC;
				EXECUTE_ALU_INPUT_B_IS_IMMEDIATE <= DECODE_ALU_INPUT_B_IS_IMMEDIATE;
				EXECUTE_ALU_IS_WORD_OPERATION <= DECODE_ALU_IS_WORD_OPERATION;
				EXECUTE_PREDICTED_BRANCH_TAKEN <= DECODE_PREDICTED_BRANCH_TAKEN;
				EXECUTE_GSHARE_INDEX <= DECODE_GSHARE_INDEX;
				EXECUTE_GLOBAL_HISTORY_CHECKPOINT <= DECODE_GLOBAL_HISTORY_CHECKPOINT;
				EXECUTE_WRITEBACK_SELECT <= DECODE_WRITEBACK_SELECT;
				EXECUTE_ALU_OPERATION <= DECODE_ALU_OPERATION;
				EXECUTE_LATE_RESULT <= !DECODE_TAKES_INTERRUPT && (((((DECODE_ALU_OPERATION == 6'd38) || (DECODE_ALU_OPERATION == 6'd32)) || (DECODE_ALU_OPERATION == 6'd33)) || (DECODE_ALU_OPERATION == 6'd34)) || (DECODE_ALU_OPERATION == 6'd35));
				EXECUTE_ALU_SUBTRACT <= ((((((DECODE_ALU_OPERATION == 6'd1) || (DECODE_ALU_OPERATION == 6'd5)) || (DECODE_ALU_OPERATION == 6'd6)) || (DECODE_ALU_OPERATION == 6'd32)) || (DECODE_ALU_OPERATION == 6'd33)) || (DECODE_ALU_OPERATION == 6'd34)) || (DECODE_ALU_OPERATION == 6'd35);
				EXECUTE_MULTIPLY_DIVIDE_PREDECODED <= {(((DECODE_ALU_OPERATION == 6'd17) || (DECODE_ALU_OPERATION == 6'd18)) || (DECODE_ALU_OPERATION == 6'd20)) || (DECODE_ALU_OPERATION == 6'd22), ((DECODE_ALU_OPERATION == 6'd17) || (DECODE_ALU_OPERATION == 6'd20)) || (DECODE_ALU_OPERATION == 6'd22), DECODE_ALU_IS_WORD_OPERATION && ((((DECODE_ALU_OPERATION == 6'd20) || (DECODE_ALU_OPERATION == 6'd21)) || (DECODE_ALU_OPERATION == 6'd22)) || (DECODE_ALU_OPERATION == 6'd23))};
				EXECUTE_PC_TARGET <= DECODE_PC_TARGET;
				EXECUTE_PC_ADD_4 <= DECODE_PC_ADD_4;
				EXECUTE_RAS_CHECKPOINT <= DECODE_RAS_CHECKPOINT;
				EXECUTE_GSHARE_PREDICTED_TAKEN <= DECODE_GSHARE_PREDICTED_TAKEN;
				EXECUTE_BHT_PREDICTED_TAKEN <= DECODE_BHT_PREDICTED_TAKEN;
			end
			if (FRONT_END_NOT_STALLED) begin
				DECODE_PC <= FETCH2_PC;
				DECODE_INSTRUCTION <= FETCH2_INSTRUCTION;
				DECODE_PREDICTED_BRANCH_TAKEN <= FETCH2_PREDICTED_BRANCH_TAKEN;
				DECODE_GSHARE_INDEX <= FETCH2_GSHARE_INDEX;
				DECODE_GLOBAL_HISTORY_CHECKPOINT <= GLOBAL_HISTORY;
				DECODE_PC_TARGET <= FETCH2_REDIRECT_TARGET;
				DECODE_PC_ADD_4 <= FETCH2_PC_ADD_4;
				DECODE_RETURN_PREDICTED <= FETCH2_RETURN_PREDICTED;
				DECODE_IS_A_CALL <= RAS_ENABLE && FETCH2_IS_A_CALL;
				DECODE_IS_A_RETURN <= RAS_ENABLE && FETCH2_IS_A_RETURN;
				DECODE_RAS_CHECKPOINT <= RETURN_ADDRESS_STACK_POINTER;
				DECODE_GSHARE_PREDICTED_TAKEN <= FETCH2_GSHARE_PREDICTED_TAKEN;
				DECODE_BHT_PREDICTED_TAKEN <= FETCH2_BHT_PREDICTED_TAKEN;
				FETCH2_GSHARE_PREDICTED_TAKEN <= FETCH1_GSHARE_PREDICTED_TAKEN;
				FETCH2_BHT_PREDICTED_TAKEN <= FETCH1_BHT_PREDICTED_TAKEN;
				FETCH2_PC <= FETCH1_PC;
				FETCH2_PC_ADD_4 <= FETCH1_PC_ADD_4;
				FETCH2_INSTRUCTION <= icache_dout;
				FETCH2_PREDICTED_BRANCH_TAKEN <= FETCH1_PREDICTED_BRANCH_TAKEN;
				FETCH2_GSHARE_INDEX <= FETCH1_GSHARE_INDEX;
				FETCH2_BTB_REDIRECTED <= FETCH1_BTB_REDIRECT;
			end
			if (FLUSH_FETCH1_FETCH2_DECODE) begin
				EXECUTE_VALID <= 1'b0;
				EXECUTE_INSTRUCTION <= const_pkg_INSTR_NOP;
				EXECUTE_REGISTER_WRITE_ENABLE <= 1'b0;
				EXECUTE_MEMORY_READ_ENABLE <= 1'b0;
				EXECUTE_MEMORY_WRITE_ENABLE <= 1'b0;
				EXECUTE_CSR_WRITE_ENABLE <= 1'b0;
				EXECUTE_IS_A_BRANCH_INSTRUCTION <= 1'b0;
				EXECUTE_IS_A_JAL_INSTRUCTION <= 1'b0;
				EXECUTE_IS_A_JALR_INSTRUCTION <= 1'b0;
				EXECUTE_IS_AN_ECALL <= 1'b0;
				EXECUTE_IS_AN_EBREAK <= 1'b0;
				EXECUTE_IS_AN_MRET <= 1'b0;
				EXECUTE_IS_AN_INTERRUPT <= 1'b0;
				DECODE_VALID <= 1'b0;
				FETCH1_PC <= EXECUTE_REDIRECT_PC;
				FETCH2_VALID <= 1'b0;
			end
			else if (DATA_CACHE_STALL) begin
				MEMORY_VALID <= 1'b0;
				MEMORY_REGISTER_WRITE_ENABLE <= 1'b0;
				MEMORY_WRITES_TOHOST <= 1'b0;
			end
			else if (LOAD_STALL) begin
				EXECUTE_VALID <= 1'b0;
				EXECUTE_INSTRUCTION <= const_pkg_INSTR_NOP;
				EXECUTE_REGISTER_WRITE_ENABLE <= 1'b0;
				EXECUTE_MEMORY_READ_ENABLE <= 1'b0;
				EXECUTE_MEMORY_WRITE_ENABLE <= 1'b0;
				EXECUTE_CSR_WRITE_ENABLE <= 1'b0;
				EXECUTE_IS_A_BRANCH_INSTRUCTION <= 1'b0;
				EXECUTE_IS_A_JAL_INSTRUCTION <= 1'b0;
				EXECUTE_IS_A_JALR_INSTRUCTION <= 1'b0;
				EXECUTE_IS_AN_ECALL <= 1'b0;
				EXECUTE_IS_AN_EBREAK <= 1'b0;
				EXECUTE_IS_AN_MRET <= 1'b0;
				EXECUTE_IS_AN_INTERRUPT <= 1'b0;
			end
			else if (MULTIPLY_DIVIDE_STALL) begin
				MEMORY_VALID <= 1'b0;
				MEMORY_REGISTER_WRITE_ENABLE <= 1'b0;
				MEMORY_WRITES_TOHOST <= 1'b0;
			end
			else begin
				EXECUTE_VALID <= DECODE_VALID;
				EXECUTE_INSTRUCTION <= DECODE_INSTRUCTION;
				EXECUTE_REGISTER_WRITE_ENABLE <= DECODE_REGISTER_WRITE_ENABLE;
				EXECUTE_MEMORY_READ_ENABLE <= DECODE_MEMORY_READ_ENABLE;
				EXECUTE_MEMORY_WRITE_ENABLE <= DECODE_MEMORY_WRITE_ENABLE;
				EXECUTE_CSR_WRITE_ENABLE <= DECODE_CSR_WRITE_ENABLE;
				EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION <= DECODE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION;
				EXECUTE_IS_A_BRANCH_INSTRUCTION <= DECODE_IS_A_BRANCH_INSTRUCTION;
				EXECUTE_IS_A_JAL_INSTRUCTION <= DECODE_IS_A_JAL_INSTRUCTION;
				EXECUTE_IS_A_JALR_INSTRUCTION <= DECODE_IS_A_JALR_INSTRUCTION;
				EXECUTE_RETURN_PREDICTED <= DECODE_RETURN_PREDICTED;
				EXECUTE_IS_A_CALL <= DECODE_IS_A_CALL;
				EXECUTE_IS_A_RETURN <= DECODE_IS_A_RETURN;
				EXECUTE_IS_AN_ECALL <= DECODE_IS_AN_ECALL;
				EXECUTE_IS_AN_EBREAK <= DECODE_IS_AN_EBREAK;
				EXECUTE_IS_AN_MRET <= DECODE_IS_AN_MRET;
				EXECUTE_IS_AN_INTERRUPT <= 1'b0;
				EXECUTE_INTERRUPT_IS_EXTERNAL <= INTERRUPT_IS_EXTERNAL;
				if (DECODE_TAKES_INTERRUPT) begin
					EXECUTE_REGISTER_WRITE_ENABLE <= 1'b0;
					EXECUTE_MEMORY_READ_ENABLE <= 1'b0;
					EXECUTE_MEMORY_WRITE_ENABLE <= 1'b0;
					EXECUTE_CSR_WRITE_ENABLE <= 1'b0;
					EXECUTE_IS_A_MULTIPLY_DIVIDE_INSTRUCTION <= 1'b0;
					EXECUTE_IS_A_BRANCH_INSTRUCTION <= 1'b0;
					EXECUTE_IS_A_JAL_INSTRUCTION <= 1'b0;
					EXECUTE_IS_A_JALR_INSTRUCTION <= 1'b0;
					EXECUTE_RETURN_PREDICTED <= 1'b0;
					EXECUTE_IS_A_CALL <= 1'b0;
					EXECUTE_IS_A_RETURN <= 1'b0;
					EXECUTE_IS_AN_ECALL <= 1'b0;
					EXECUTE_IS_AN_EBREAK <= 1'b0;
					EXECUTE_IS_AN_MRET <= 1'b0;
					EXECUTE_IS_AN_INTERRUPT <= 1'b1;
				end
				DECODE_VALID <= FETCH2_VALID;
				FETCH2_VALID <= !FETCH2_BRANCH_OFF_OR_CONTINUE && icache_hit;
				FETCH1_PC <= FETCH2_PREDICTED_NEXT_PC;
			end
		end
	assign TRACE_VALID = {WRITEBACK_VALID, MEMORY_VALID, EXECUTE_VALID, DECODE_VALID, FETCH2_VALID, 1'b1};
	assign TRACE_FETCH1_PC = FETCH1_PC;
	assign TRACE_FETCH2_PC = FETCH2_PC;
	assign TRACE_DECODE_PC = DECODE_PC;
	assign TRACE_EXECUTE_PC = EXECUTE_PC;
	assign TRACE_MEMORY_PC = MEMORY_PC;
	assign TRACE_WRITEBACK_PC = WRITEBACK_PC;
	assign TRACE_LOAD_STALL = (LOAD_STALL && !FLUSH_FETCH1_FETCH2_DECODE) && !DATA_CACHE_STALL;
	assign TRACE_INSTRUCTION_MISS = (ADVANCE_FRONT_END && !FETCH2_BRANCH_OFF_OR_CONTINUE) && !icache_hit;
	assign TRACE_DATA_MISS = DATA_CACHE_STALL && !FLUSH_FETCH1_FETCH2_DECODE;
	assign TRACE_FLUSH = FLUSH_FETCH1_FETCH2_DECODE;
	assign TRACE_REDIRECT = FETCH2_BRANCH_OFF_OR_CONTINUE && ADVANCE_FRONT_END;
	assign TRACE_MULTIPLY_DIVIDE_STALL = MULTIPLY_DIVIDE_STALL && !FLUSH_FETCH1_FETCH2_DECODE;
	wire UNUSED_SIGNALS;
	assign UNUSED_SIGNALS = ^{EXECUTE_PREDICTION_WAS_WRONG, EXECUTE_IMMEDIATE[0], MEMORY_PC[0], MEMORY_REGISTER_WRITE_ENABLE_OUT};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module MainMemory (
	clk,
	WRITE_ADDRESS,
	WRITE_MASK,
	WRITE_DATA,
	INSTRUCTION_REFILL_ADDRESS,
	INSTRUCTION_REFILL_LINE,
	DATA_REFILL_ADDRESS,
	DATA_REFILL_LINE
);
	reg _sv2v_0;
	parameter INIT_FILE = "";
	parameter signed [31:0] LINES = 2048;
	input wire clk;
	input wire [15:0] WRITE_ADDRESS;
	input wire [7:0] WRITE_MASK;
	input wire [63:0] WRITE_DATA;
	input wire [15:0] INSTRUCTION_REFILL_ADDRESS;
	output wire [255:0] INSTRUCTION_REFILL_LINE;
	input wire [15:0] DATA_REFILL_ADDRESS;
	output wire [255:0] DATA_REFILL_LINE;
	localparam signed [31:0] INDEX_BITS = $clog2(LINES);
	wire [INDEX_BITS - 1:0] WRITE_INDEX;
	reg [31:0] WRITE_ENABLES;
	wire [255:0] WRITE_LINE;
	assign WRITE_INDEX = WRITE_ADDRESS[INDEX_BITS + 4:5];
	assign WRITE_LINE = {4 {WRITE_DATA}};
	always @(*) begin
		if (_sv2v_0)
			;
		WRITE_ENABLES = 32'd0;
		WRITE_ENABLES[8 * WRITE_ADDRESS[4:3]+:8] = WRITE_MASK;
	end
	reg [INDEX_BITS - 1:0] LAST_WRITE_INDEX;
	reg [31:0] LAST_WRITE_ENABLES;
	reg [255:0] LAST_WRITE_LINE;
	always @(posedge clk) begin
		LAST_WRITE_INDEX <= WRITE_INDEX;
		LAST_WRITE_ENABLES <= WRITE_ENABLES;
		LAST_WRITE_LINE <= WRITE_LINE;
	end
	wire [INDEX_BITS - 1:0] READ_INDEX [0:1];
	reg [255:0] READ_LINE [0:1];
	assign READ_INDEX[0] = INSTRUCTION_REFILL_ADDRESS[INDEX_BITS + 4:5];
	assign READ_INDEX[1] = DATA_REFILL_ADDRESS[INDEX_BITS + 4:5];
	genvar _gv_COPY_1;
	generate
		for (_gv_COPY_1 = 0; _gv_COPY_1 < 2; _gv_COPY_1 = _gv_COPY_1 + 1) begin : copy
			localparam COPY = _gv_COPY_1;
			reg [255:0] RAM [0:LINES - 1];
			reg [255:0] RAM_OUTPUT;
			reg [INDEX_BITS - 1:0] REGISTERED_READ_INDEX;
			initial if (INIT_FILE != "")
				$readmemh(INIT_FILE, RAM);
			always @(posedge clk) begin
				begin : sv2v_autoblock_1
					reg signed [31:0] LANE;
					for (LANE = 0; LANE < 32; LANE = LANE + 1)
						if (WRITE_ENABLES[LANE])
							RAM[WRITE_INDEX][8 * LANE+:8] <= WRITE_LINE[8 * LANE+:8];
				end
				RAM_OUTPUT <= RAM[READ_INDEX[COPY]];
				REGISTERED_READ_INDEX <= READ_INDEX[COPY];
			end
			always @(*) begin
				if (_sv2v_0)
					;
				READ_LINE[COPY] = RAM_OUTPUT;
				if (REGISTERED_READ_INDEX == LAST_WRITE_INDEX) begin : sv2v_autoblock_2
					reg signed [31:0] LANE;
					for (LANE = 0; LANE < 32; LANE = LANE + 1)
						if (LAST_WRITE_ENABLES[LANE])
							READ_LINE[COPY][8 * LANE+:8] = LAST_WRITE_LINE[8 * LANE+:8];
				end
			end
		end
	endgenerate
	assign INSTRUCTION_REFILL_LINE = READ_LINE[0];
	assign DATA_REFILL_LINE = READ_LINE[1];
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
`default_nettype wire
`default_nettype none
module hydra_tt_regs (
	clk,
	rst_n,
	cs_start,
	cs_end,
	rx_valid,
	rx_byte,
	rx_index,
	tx_load,
	tx_byte,
	wd_valid,
	wd_ready,
	wd,
	disp_valid,
	disp_accept,
	disp_fire,
	disp_engine,
	disp_tag,
	disp_wd,
	comp_valid,
	comp_tag,
	fence_tag,
	fence_busy,
	csr_wr,
	csr_priv,
	csr_engine,
	csr_data,
	csr_bw_dma_log2,
	csr_eps_mem,
	csr_e_shift,
	csr_cal_freeze,
	csr_cal_reset,
	err_unsupported,
	err_tag,
	err_stale_comp,
	obs_margin,
	obs_cal_updates,
	obs_tag_busy,
	irq,
	last_engine,
	disp_sticky,
	last_tag,
	margin_nib
);
	reg _sv2v_0;
	parameter [31:0] NTAG = 8;
	parameter [0:0] HOST_COMP = 1'b1;
	input wire clk;
	input wire rst_n;
	input wire cs_start;
	input wire cs_end;
	input wire rx_valid;
	input wire [7:0] rx_byte;
	input wire [4:0] rx_index;
	input wire tx_load;
	output reg [7:0] tx_byte;
	output wire wd_valid;
	input wire wd_ready;
	localparam [31:0] mom_pkg_WD_W = 128;
	output wire [127:0] wd;
	input wire disp_valid;
	output wire disp_accept;
	input wire disp_fire;
	input wire [2:0] disp_engine;
	input wire [3:0] disp_tag;
	input wire [127:0] disp_wd;
	output reg comp_valid;
	output reg [3:0] comp_tag;
	output wire [3:0] fence_tag;
	input wire fence_busy;
	output reg csr_wr;
	output wire csr_priv;
	output reg [2:0] csr_engine;
	localparam [31:0] mom_pkg_EPARAM_W = 43;
	output reg [42:0] csr_data;
	output wire [3:0] csr_bw_dma_log2;
	output wire [3:0] csr_eps_mem;
	output wire [3:0] csr_e_shift;
	output wire csr_cal_freeze;
	output wire csr_cal_reset;
	input wire err_unsupported;
	input wire [7:0] err_tag;
	input wire err_stale_comp;
	localparam [31:0] mom_pkg_COST_W = 32;
	input wire [31:0] obs_margin;
	input wire [15:0] obs_cal_updates;
	input wire [NTAG - 1:0] obs_tag_busy;
	output wire irq;
	output wire [2:0] last_engine;
	output wire disp_sticky;
	output wire [3:0] last_tag;
	output wire [3:0] margin_nib;
	localparam [6:0] A_ID = 7'h00;
	localparam [6:0] A_WD = 7'h01;
	localparam [6:0] A_CTRL = 7'h02;
	localparam [6:0] A_ACTION = 7'h03;
	localparam [6:0] A_COMP = 7'h04;
	localparam [6:0] A_STATUS = 7'h05;
	localparam [6:0] A_RESULT = 7'h06;
	localparam [6:0] A_LASTWD = 7'h07;
	localparam [6:0] A_CALUPD = 7'h08;
	localparam [6:0] A_BUSY = 7'h09;
	localparam [6:0] A_FENCE = 7'h0a;
	localparam [6:0] A_PARAM = 7'h0b;
	localparam [6:0] A_GLOBAL = 7'h0c;
	localparam [6:0] A_INFO = 7'h0d;
	localparam [7:0] NTAG8 = NTAG[7:0];
	localparam [31:0] ID_VALUE = 32'h48594d32;
	function automatic [4:0] reg_len;
		input reg [6:0] a;
		case (a)
			A_ID: reg_len = 5'd4;
			A_WD: reg_len = 5'd16;
			A_CTRL: reg_len = 5'd1;
			A_ACTION: reg_len = 5'd1;
			A_COMP: reg_len = 5'd1;
			A_STATUS: reg_len = 5'd2;
			A_RESULT: reg_len = 5'd6;
			A_LASTWD: reg_len = 5'd16;
			A_CALUPD: reg_len = 5'd2;
			A_BUSY: reg_len = 5'd2;
			A_FENCE: reg_len = 5'd1;
			A_PARAM: reg_len = 5'd6;
			A_GLOBAL: reg_len = 5'd2;
			A_INFO: reg_len = 5'd1;
			default: reg_len = 5'd0;
		endcase
	endfunction
	function automatic writable;
		input reg [6:0] a;
		writable = ((((((a == A_WD) || (a == A_CTRL)) || (a == A_ACTION)) || (HOST_COMP && (a == A_COMP))) || (a == A_FENCE)) || (a == A_PARAM)) || (a == A_GLOBAL);
	endfunction
	reg have_cmd;
	reg cmd_rd;
	reg [6:0] cmd_addr;
	reg [4:0] n_data;
	reg [47:0] wbuf;
	reg [127:0] wd_q;
	reg wd_ok;
	reg hold_q;
	reg cal_freeze_q;
	reg cal_reset_q;
	reg param_lock_q;
	reg [3:0] fence_q;
	reg [11:0] global_q;
	reg pending_q;
	reg wd_block_q;
	reg s_disp;
	reg s_unsupp;
	reg s_stale;
	reg s_frame;
	reg s_goerr;
	reg [2:0] r_engine;
	reg [3:0] r_tag;
	reg [31:0] r_margin;
	reg [7:0] r_errtag;
	reg [127:0] r_lastwd;
	wire dispatched = disp_fire;
	wire frame_ok = (((have_cmd && !cmd_rd) && writable(cmd_addr)) && (n_data == reg_len(cmd_addr))) && !wd_block_q;
	wire frame_bad = ((have_cmd && !cmd_rd) && !frame_ok) || wd_block_q;
	wire commit = cs_end && frame_ok;
	wire [7:0] w8 = wbuf[7:0];
	wire do_go = (commit && (cmd_addr == A_ACTION)) && w8[0];
	wire do_clear = (commit && (cmd_addr == A_ACTION)) && w8[1];
	wire go_accept = (do_go && wd_ok) && !pending_q;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			have_cmd <= 1'b0;
			cmd_rd <= 1'b0;
			cmd_addr <= 7'd0;
			n_data <= 5'd0;
			wbuf <= 48'd0;
			wd_q <= {mom_pkg_WD_W {1'b0}};
			wd_ok <= 1'b0;
			hold_q <= 1'b0;
			cal_freeze_q <= 1'b0;
			cal_reset_q <= 1'b0;
			param_lock_q <= 1'b0;
			fence_q <= 4'd0;
			global_q <= 12'h4c8;
			pending_q <= 1'b0;
			wd_block_q <= 1'b0;
			comp_valid <= 1'b0;
			comp_tag <= 4'd0;
			csr_wr <= 1'b0;
			csr_engine <= 3'd0;
			csr_data <= {mom_pkg_EPARAM_W {1'b0}};
			s_disp <= 1'b0;
			s_unsupp <= 1'b0;
			s_stale <= 1'b0;
			s_frame <= 1'b0;
			s_goerr <= 1'b0;
			r_engine <= 3'd0;
			r_tag <= 4'd0;
			r_margin <= {mom_pkg_COST_W {1'b0}};
			r_errtag <= 8'd0;
			r_lastwd <= {mom_pkg_WD_W {1'b0}};
		end
		else begin
			comp_valid <= 1'b0;
			csr_wr <= 1'b0;
			if (cs_start) begin
				have_cmd <= 1'b0;
				n_data <= 5'd0;
				wd_block_q <= 1'b0;
			end
			if (rx_valid) begin
				if (rx_index == 5'd0) begin
					have_cmd <= 1'b1;
					cmd_rd <= rx_byte[7];
					cmd_addr <= rx_byte[6:0];
					if (!rx_byte[7] && (rx_byte[6:0] == A_WD)) begin
						if (pending_q)
							wd_block_q <= 1'b1;
						else
							wd_ok <= 1'b0;
					end
				end
				else if (have_cmd) begin
					if (n_data != 5'd31)
						n_data <= n_data + 5'd1;
					if (!cmd_rd) begin
						if (cmd_addr == A_WD) begin
							if (!wd_block_q)
								wd_q <= {wd_q[119:0], rx_byte};
						end
						else
							wbuf <= {wbuf[39:0], rx_byte};
					end
				end
			end
			if (cs_end) begin
				have_cmd <= 1'b0;
				wd_block_q <= 1'b0;
				if (frame_bad)
					s_frame <= 1'b1;
			end
			if (commit)
				case (cmd_addr)
					A_WD: wd_ok <= 1'b1;
					A_CTRL: begin
						hold_q <= w8[0];
						cal_freeze_q <= w8[1];
						cal_reset_q <= w8[2];
						param_lock_q <= param_lock_q | w8[3];
					end
					A_COMP: begin
						comp_valid <= 1'b1;
						comp_tag <= w8[3:0];
					end
					A_FENCE: fence_q <= w8[3:0];
					A_GLOBAL: global_q <= wbuf[11:0];
					A_PARAM:
						if (!param_lock_q) begin
							csr_wr <= 1'b1;
							csr_engine <= wbuf[45:43];
							csr_data <= wbuf[42:0];
						end
					default:
						;
				endcase
			if (pending_q && wd_ready)
				pending_q <= 1'b0;
			if (go_accept) begin
				pending_q <= 1'b1;
				s_disp <= 1'b0;
				s_unsupp <= 1'b0;
			end
			if (do_go && !go_accept)
				s_goerr <= 1'b1;
			if (dispatched) begin
				r_engine <= disp_engine;
				r_tag <= disp_tag;
				r_margin <= obs_margin;
				r_lastwd <= disp_wd;
				s_disp <= 1'b1;
			end
			if (err_unsupported) begin
				s_unsupp <= 1'b1;
				r_errtag <= err_tag;
			end
			if (err_stale_comp)
				s_stale <= 1'b1;
			if (do_clear) begin
				s_disp <= 1'b0;
				s_unsupp <= 1'b0;
				s_stale <= 1'b0;
				s_frame <= 1'b0;
				s_goerr <= 1'b0;
			end
		end
	assign wd_valid = pending_q;
	assign wd = wd_q;
	assign disp_accept = ~hold_q;
	assign fence_tag = fence_q;
	assign csr_priv = 1'b1;
	assign csr_bw_dma_log2 = global_q[11:8];
	assign csr_eps_mem = global_q[7:4];
	assign csr_e_shift = global_q[3:0];
	assign csr_cal_freeze = cal_freeze_q;
	assign csr_cal_reset = cal_reset_q;
	wire any_busy = |obs_tag_busy;
	wire [15:0] status_w = {wd_ready, any_busy, pending_q, wd_ok, s_disp, s_unsupp, s_stale, s_frame, s_goerr, fence_busy, param_lock_q, hold_q, cal_freeze_q, cal_reset_q, 2'b00};
	reg [15:0] busy16;
	always @(*) begin
		if (_sv2v_0)
			;
		busy16 = 16'd0;
		busy16[NTAG - 1:0] = obs_tag_busy;
	end
	reg [127:0] rval;
	always @(*) begin
		if (_sv2v_0)
			;
		case (cmd_addr)
			A_ID: rval = {{96 {1'b0}}, ID_VALUE};
			A_WD: rval = wd_q;
			A_CTRL: rval = {{124 {1'b0}}, param_lock_q, cal_reset_q, cal_freeze_q, hold_q};
			A_STATUS: rval = {{112 {1'b0}}, status_w};
			A_RESULT: rval = {{80 {1'b0}}, r_engine, r_tag, 1'b0, r_margin, r_errtag};
			A_LASTWD: rval = r_lastwd;
			A_CALUPD: rval = {{112 {1'b0}}, obs_cal_updates};
			A_BUSY: rval = {{112 {1'b0}}, busy16};
			A_FENCE: rval = {{124 {1'b0}}, fence_q};
			A_GLOBAL: rval = {{116 {1'b0}}, global_q};
			A_INFO: rval = {{120 {1'b0}}, NTAG8};
			default: rval = {mom_pkg_WD_W {1'b0}};
		endcase
	end
	wire [4:0] len = reg_len(cmd_addr);
	wire [4:0] k = n_data;
	wire [4:0] kofs = (len - 5'd1) - k;
	wire [6:0] sh = {kofs[3:0], 3'b000};
	wire in_rng = (have_cmd && cmd_rd) && (k < len);
	reg [39:0] snap_q;
	wire snap_use = (k != 5'd0) && (len <= 5'd6);
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			snap_q <= 40'd0;
		else if ((tx_load && in_rng) && (k == 5'd0))
			snap_q <= rval[39:0];
	always @(*) begin
		if (_sv2v_0)
			;
		if (!have_cmd)
			tx_byte = status_w[15:8];
		else if (in_rng)
			tx_byte = (snap_use ? snap_q[sh[5:0]+:8] : rval[sh+:8]);
		else
			tx_byte = 8'h00;
	end
	assign irq = (((s_disp | s_unsupp) | s_stale) | s_frame) | s_goerr;
	assign last_engine = r_engine;
	assign disp_sticky = s_disp;
	assign last_tag = r_tag;
	reg [3:0] mlog;
	always @(*) begin
		if (_sv2v_0)
			;
		mlog = 4'd0;
		begin : sv2v_autoblock_1
			reg signed [31:0] b;
			for (b = 0; b < mom_pkg_COST_W; b = b + 1)
				if (r_margin[b])
					mlog = (b >= 14 ? 4'd15 : b[3:0] + 4'd1);
		end
	end
	assign margin_nib = mlog;
	wire _unused_ok = &{1'b0, disp_valid, wbuf[47:46], w8[7:4], kofs[4]};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_tt_spi (
	clk,
	rst_n,
	sck_i,
	copi_i,
	csn_i,
	cipo_o,
	cs_start,
	cs_end,
	cs_active,
	rx_valid,
	rx_byte,
	rx_index,
	tx_load,
	tx_byte
);
	input wire clk;
	input wire rst_n;
	input wire sck_i;
	input wire copi_i;
	input wire csn_i;
	output wire cipo_o;
	output reg cs_start;
	output reg cs_end;
	output wire cs_active;
	output reg rx_valid;
	output reg [7:0] rx_byte;
	output reg [4:0] rx_index;
	output reg tx_load;
	input wire [7:0] tx_byte;
	reg [2:0] sck_s;
	reg [2:0] csn_s;
	reg [1:0] copi_s;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			sck_s <= 3'b000;
			csn_s <= 3'b111;
			copi_s <= 2'b00;
		end
		else begin
			sck_s <= {sck_s[1:0], sck_i};
			csn_s <= {csn_s[1:0], csn_i};
			copi_s <= {copi_s[0], copi_i};
		end
	wire sck_rise = sck_s[2:1] == 2'b01;
	wire sck_fall = sck_s[2:1] == 2'b10;
	wire cs_fall = csn_s[2:1] == 2'b10;
	wire cs_rise = csn_s[2:1] == 2'b01;
	wire copi_b = copi_s[1];
	assign cs_active = ~csn_s[1];
	reg [2:0] bitcnt;
	reg [6:0] rx_sr;
	reg boundary;
	reg [4:0] byte_cnt;
	reg [7:0] tx_sr;
	assign cipo_o = tx_sr[7];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			bitcnt <= 3'd0;
			rx_sr <= 7'd0;
			rx_byte <= 8'd0;
			rx_valid <= 1'b0;
			rx_index <= 5'd0;
			byte_cnt <= 5'd0;
			boundary <= 1'b0;
			tx_sr <= 8'd0;
			tx_load <= 1'b0;
			cs_start <= 1'b0;
			cs_end <= 1'b0;
		end
		else begin
			rx_valid <= 1'b0;
			tx_load <= 1'b0;
			cs_start <= cs_fall;
			cs_end <= cs_rise;
			if (cs_fall) begin
				bitcnt <= 3'd0;
				byte_cnt <= 5'd0;
				boundary <= 1'b0;
				tx_load <= 1'b1;
			end
			else if (cs_active) begin
				if (sck_rise) begin
					rx_sr <= {rx_sr[5:0], copi_b};
					bitcnt <= bitcnt + 3'd1;
					if (bitcnt == 3'd7) begin
						rx_byte <= {rx_sr, copi_b};
						rx_valid <= 1'b1;
						rx_index <= byte_cnt;
						if (byte_cnt != 5'd31)
							byte_cnt <= byte_cnt + 5'd1;
						boundary <= 1'b1;
					end
				end
				else if (sck_fall) begin
					if (boundary) begin
						boundary <= 1'b0;
						tx_load <= 1'b1;
					end
					else
						tx_sr <= {tx_sr[6:0], 1'b0};
				end
			end
			if (tx_load)
				tx_sr <= tx_byte;
		end
endmodule
`default_nettype wire
`default_nettype none
module mom_calibrate (
	clk,
	rst_n,
	freeze,
	reset_factors,
	rd_opclass,
	rd_k,
	upd_valid,
	upd_engine,
	upd_opclass,
	upd_t_measured,
	upd_t_predicted,
	upd_count,
	last_dir
);
	localparam [31:0] mom_pkg_ENG_N = 5;
	parameter [31:0] NENG = mom_pkg_ENG_N;
	localparam [31:0] mom_pkg_KCAL_ALPHA = 4;
	parameter [31:0] ALPHA = mom_pkg_KCAL_ALPHA;
	parameter [7:0] K_MIN = 8'd4;
	parameter [7:0] K_MAX = 8'd255;
	input wire clk;
	input wire rst_n;
	input wire freeze;
	input wire reset_factors;
	input wire [3:0] rd_opclass;
	output wire [(NENG * 8) - 1:0] rd_k;
	input wire upd_valid;
	input wire [2:0] upd_engine;
	input wire [3:0] upd_opclass;
	localparam [31:0] mom_pkg_COST_W = 32;
	input wire [31:0] upd_t_measured;
	input wire [31:0] upd_t_predicted;
	output reg [15:0] upd_count;
	output reg last_dir;
	localparam [31:0] NOPC = 9;
	reg [7:0] k [0:NENG - 1][0:8];
	genvar _gv_e_1;
	localparam [7:0] mom_pkg_KCAL_UNITY = 8'd64;
	generate
		for (_gv_e_1 = 0; _gv_e_1 < NENG; _gv_e_1 = _gv_e_1 + 1) begin : g_rd
			localparam e = _gv_e_1;
			assign rd_k[e * 8+:8] = ({28'd0, rd_opclass} < NOPC ? k[e][rd_opclass] : mom_pkg_KCAL_UNITY);
		end
	endgenerate
	wire upd_idx_ok = ({29'd0, upd_engine} < NENG) && ({28'd0, upd_opclass} < NOPC);
	wire [7:0] k_cur = (upd_idx_ok ? k[upd_engine][upd_opclass] : mom_pkg_KCAL_UNITY);
	wire [39:0] t_cal_wide = upd_t_predicted * {32'd0, k_cur};
	localparam [31:0] mom_pkg_KCAL_SHIFT = 6;
	wire [33:0] t_cal = t_cal_wide[39:mom_pkg_KCAL_SHIFT];
	wire too_slow = {2'b00, upd_t_measured} > t_cal;
	wire too_fast = {2'b00, upd_t_measured} < t_cal;
	function automatic [7:0] step_of;
		input reg [7:0] kc;
		reg [7:0] raw;
		begin
			raw = kc >> ALPHA;
			step_of = (raw == 8'd0 ? 8'd1 : raw);
		end
	endfunction
	function automatic [7:0] k_up_of;
		input reg [7:0] kc;
		reg [8:0] w;
		begin
			w = {1'b0, kc} + {1'b0, step_of(kc)};
			k_up_of = (w > {1'b0, K_MAX} ? K_MAX : w[7:0]);
		end
	endfunction
	function automatic [7:0] k_dn_of;
		input reg [7:0] kc;
		reg [8:0] w;
		begin
			w = {1'b0, kc} - {1'b0, step_of(kc)};
			k_dn_of = (w[8] || (w[7:0] < K_MIN) ? K_MIN : w[7:0]);
		end
	endfunction
	wire [7:0] k_up = k_up_of(k_cur);
	wire [7:0] k_dn = k_dn_of(k_cur);
	wire [7:0] k_next = (too_slow ? k_up : (too_fast ? k_dn : k_cur));
	wire do_update = ((upd_valid && !freeze) && (upd_t_predicted != {mom_pkg_COST_W {1'b0}})) && upd_idx_ok;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			begin : sv2v_autoblock_1
				reg signed [31:0] e;
				for (e = 0; e < NENG; e = e + 1)
					begin : sv2v_autoblock_2
						reg signed [31:0] c;
						for (c = 0; c < NOPC; c = c + 1)
							k[e][c] <= mom_pkg_KCAL_UNITY;
					end
			end
			upd_count <= 16'd0;
			last_dir <= 1'b0;
		end
		else if (reset_factors) begin
			begin : sv2v_autoblock_3
				reg signed [31:0] e;
				for (e = 0; e < NENG; e = e + 1)
					begin : sv2v_autoblock_4
						reg signed [31:0] c;
						for (c = 0; c < NOPC; c = c + 1)
							k[e][c] <= mom_pkg_KCAL_UNITY;
					end
			end
			upd_count <= 16'd0;
		end
		else if (do_update) begin
			k[upd_engine][upd_opclass] <= k_next;
			upd_count <= upd_count + 16'd1;
			last_dir <= too_slow;
		end
	wire _unused_ok = &{1'b0, t_cal_wide[5:0]};
endmodule
`default_nettype wire
`default_nettype none
module mom_cost_engine (
	clk,
	rst_n,
	adv,
	log2_w,
	bytes_q,
	log2_i,
	dtype,
	op_class,
	lat_hint,
	lambda_sh,
	param,
	k_cal,
	queue_depth,
	engine_busy_full,
	bw_dma_log2,
	eps_mem,
	e_shift,
	cost,
	t_pred,
	valid,
	capable
);
	reg _sv2v_0;
	parameter [2:0] ENGINE_ID = 3'd0;
	input wire clk;
	input wire rst_n;
	input wire adv;
	input wire [7:0] log2_w;
	input wire [23:0] bytes_q;
	input wire signed [8:0] log2_i;
	input wire [2:0] dtype;
	input wire [3:0] op_class;
	input wire [1:0] lat_hint;
	input wire [3:0] lambda_sh;
	input wire [42:0] param;
	input wire [7:0] k_cal;
	input wire [7:0] queue_depth;
	input wire engine_busy_full;
	input wire [3:0] bw_dma_log2;
	input wire [3:0] eps_mem;
	input wire [3:0] e_shift;
	localparam [31:0] mom_pkg_COST_W = 32;
	output reg [31:0] cost;
	output wire [31:0] t_pred;
	output wire valid;
	output wire capable;
	function automatic mom_pkg_dtype_ok;
		input reg [5:0] mask;
		input reg [2:0] dt;
		mom_pkg_dtype_ok = |(mask & (6'd1 << dt));
	endfunction
	wire dt_supported = mom_pkg_dtype_ok(param[14-:6], dtype);
	function automatic mom_pkg_opc_ok;
		input reg [8:0] mask;
		input reg [3:0] oc;
		mom_pkg_opc_ok = |(mask & (9'd1 << oc));
	endfunction
	wire opc_supported = mom_pkg_opc_ok(param[8-:9], op_class);
	wire capable_a = dt_supported && opc_supported;
	wire valid_a = capable_a && !engine_busy_full;
	wire signed [9:0] bw_bound_s = log2_i + $signed({6'd0, param[26-:4]});
	wire [3:0] bw_bound = (bw_bound_s <= 0 ? 4'd0 : (bw_bound_s >= 15 ? 4'd15 : bw_bound_s[3:0]));
	wire [3:0] lg_p_att = (bw_bound < param[42-:4] ? bw_bound : param[42-:4]);
	wire [7:0] lg_t_comp = (log2_w > {4'd0, lg_p_att} ? log2_w - {4'd0, lg_p_att} : 8'd0);
	wire [4:0] sh_amt = (lg_t_comp > 8'd31 ? 5'd31 : lg_t_comp[4:0]);
	localparam [31:0] mom_pkg_COST_SAT = 32'hffff0000;
	wire [31:0] t_compute = (lg_t_comp > 8'd31 ? mom_pkg_COST_SAT : 32'd1 << sh_amt);
	wire [31:0] t_move = {8'd0, bytes_q} >> bw_dma_log2;
	wire [1:0] setup_sh = (lat_hint == 2'd3 ? 2'd2 : (lat_hint == 2'd2 ? 2'd1 : 2'd0));
	wire [39:0] t_setup_w = {28'd0, param[38-:12]} << setup_sh;
	wire [39:0] t_sum_w = (({8'd0, t_compute} + t_setup_w) + {8'd0, t_move}) + {32'd0, queue_depth};
	wire [31:0] t_pred_a = (t_sum_w > 40'h00ffff0000 ? mom_pkg_COST_SAT : t_sum_w[31:0]);
	reg [31:0] t_pred_q;
	reg [31:0] e_ops_q;
	reg [31:0] e_mem_q;
	reg valid_q;
	reg capable_q;
	reg lambda_en_q;
	reg [4:0] tp_e;
	always @(*) begin
		if (_sv2v_0)
			;
		if (t_pred_q[31:24] != 8'd0)
			tp_e = 5'd16;
		else if (t_pred_q[23:16] != 8'd0)
			tp_e = 5'd8;
		else
			tp_e = 5'd0;
	end
	wire [15:0] tp_m = (tp_e == 5'd16 ? t_pred_q[31:16] : (tp_e == 5'd8 ? t_pred_q[23:8] : t_pred_q[15:0]));
	wire [23:0] cal_prod = tp_m * {8'd0, k_cal};
	localparam [31:0] mom_pkg_KCAL_SHIFT = 6;
	wire signed [31:0] cal_sh32 = $signed({27'd0, tp_e}) - $signed(mom_pkg_KCAL_SHIFT);
	wire signed [6:0] cal_sh = cal_sh32[6:0];
	wire [47:0] cal_wide = (cal_sh >= 0 ? {24'd0, cal_prod} << cal_sh[5:0] : {24'd0, cal_prod} >> -cal_sh[5:0]);
	wire [31:0] t_cal = (cal_wide[47:mom_pkg_COST_W] != 16'd0 ? mom_pkg_COST_SAT : cal_wide[31:0]);
	wire [5:0] w_sh = (log2_w > 8'd31 ? 6'd31 : {1'b0, log2_w[4:0]});
	wire signed [7:0] net_sh_s = ($signed({2'b00, w_sh}) + $signed({5'b00000, lambda_sh[2:0]})) - $signed({4'b0000, e_shift});
	wire net_pos = ~net_sh_s[7];
	wire [5:0] net_mag = (net_pos ? net_sh_s[5:0] : ~net_sh_s[5:0] + 6'd1);
	wire net_ovf = net_pos && (net_mag > 6'd24);
	wire [31:0] e_ops_sc = ((log2_w > 8'd31) || net_ovf ? mom_pkg_COST_SAT : (net_pos ? {24'd0, param[22-:8]} << net_mag : {24'd0, param[22-:8]} >> net_mag));
	wire [27:0] e_mem_raw = bytes_q * {24'd0, eps_mem};
	wire signed [7:0] mem_sh_s = $signed({5'b00000, lambda_sh[2:0]}) - $signed({4'b0000, e_shift});
	wire mem_pos = ~mem_sh_s[7];
	wire [5:0] mem_mag = (mem_pos ? mem_sh_s[5:0] : ~mem_sh_s[5:0] + 6'd1);
	wire [31:0] e_mem_sc = (mem_pos ? {4'd0, e_mem_raw} << mem_mag : {4'd0, e_mem_raw} >> mem_mag);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			t_pred_q <= {mom_pkg_COST_W {1'b0}};
			e_ops_q <= 32'd0;
			e_mem_q <= 32'd0;
			valid_q <= 1'b0;
			capable_q <= 1'b0;
			lambda_en_q <= 1'b0;
		end
		else if (adv) begin
			t_pred_q <= t_pred_a;
			e_ops_q <= e_ops_sc;
			e_mem_q <= e_mem_sc;
			valid_q <= valid_a;
			capable_q <= capable_a;
			lambda_en_q <= lambda_sh[3];
		end
	assign t_pred = t_pred_q;
	assign valid = valid_q;
	assign capable = capable_q;
	wire [32:0] e_sum_w = (lambda_en_q ? {1'b0, e_ops_q} + {1'b0, e_mem_q} : 33'd0);
	wire [31:0] e_scaled = (e_sum_w[32] ? mom_pkg_COST_SAT : e_sum_w[31:0]);
	wire [mom_pkg_COST_W:0] j_sum = {1'b0, t_cal} + {1'b0, e_scaled};
	always @(*) begin
		if (_sv2v_0)
			;
		if (!valid)
			cost = {mom_pkg_COST_W {1'b1}};
		else if (j_sum[mom_pkg_COST_W])
			cost = mom_pkg_COST_SAT;
		else
			cost = j_sum[31:0];
	end
	wire _unused_ok = &{1'b0, net_sh_s[6], mem_sh_s[6], cal_sh32[31:7], ENGINE_ID};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module mom_features (
	clk,
	rst_n,
	in_valid,
	in_ready,
	in_wd,
	out_valid,
	out_ready,
	out_wd,
	out_log2_w,
	out_log2_q,
	out_log2_i
);
	reg _sv2v_0;
	input wire clk;
	input wire rst_n;
	input wire in_valid;
	output wire in_ready;
	input wire [127:0] in_wd;
	output reg out_valid;
	input wire out_ready;
	output reg [127:0] out_wd;
	output reg [7:0] out_log2_w;
	output reg [7:0] out_log2_q;
	output reg signed [8:0] out_log2_i;
	assign in_ready = !out_valid || out_ready;
	wire accept = in_valid && in_ready;
	reg [7:0] lg_m;
	reg [7:0] lg_n;
	reg [7:0] lg_k;
	reg [7:0] lg_q;
	reg [7:0] lg_w_c;
	function automatic [7:0] mom_pkg_flog2;
		input reg [31:0] v;
		reg [7:0] r;
		reg [31:0] t;
		begin
			r = 8'd0;
			t = v;
			if (t[31:16] != 16'd0) begin
				r = r + 8'd16;
				t = t >> 16;
			end
			if (t[15:8] != 8'd0) begin
				r = r + 8'd8;
				t = t >> 8;
			end
			if (t[7:4] != 4'd0) begin
				r = r + 8'd4;
				t = t >> 4;
			end
			if (t[3:2] != 2'd0) begin
				r = r + 8'd2;
				t = t >> 2;
			end
			if (t[1] != 1'b0)
				r = r + 8'd1;
			mom_pkg_flog2 = r;
		end
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		lg_m = mom_pkg_flog2({16'd0, in_wd[116-:16]});
		lg_n = mom_pkg_flog2({16'd0, in_wd[100-:16]});
		lg_k = mom_pkg_flog2({16'd0, in_wd[84-:16]});
		lg_q = mom_pkg_flog2({8'd0, in_wd[68-:24]});
		(* full_case, parallel_case *)
		case (in_wd[127-:4])
			4'd0, 4'd1, 4'd2: lg_w_c = lg_m;
			4'd3, 4'd4: lg_w_c = ((lg_m + lg_n) + lg_k) + 8'd1;
			4'd5: lg_w_c = (8'd2 + lg_n) + mom_pkg_flog2({24'd0, lg_n});
			4'd6: lg_w_c = (lg_n + mom_pkg_flog2({24'd0, lg_n})) + 8'd1;
			4'd7, 4'd8: lg_w_c = lg_q;
			default: lg_w_c = lg_m;
		endcase
	end
	wire signed [8:0] lg_i_c = $signed({1'b0, lg_w_c}) - $signed({1'b0, lg_q});
	localparam [31:0] mom_pkg_WD_W = 128;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			out_valid <= 1'b0;
			out_wd <= {mom_pkg_WD_W {1'b0}};
			out_log2_w <= 8'd0;
			out_log2_q <= 8'd0;
			out_log2_i <= 9'sd0;
		end
		else if (accept) begin
			out_valid <= 1'b1;
			out_wd <= in_wd;
			out_log2_w <= lg_w_c;
			out_log2_q <= lg_q;
			out_log2_i <= lg_i_c;
		end
		else if (out_ready)
			out_valid <= 1'b0;
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module mom_param_rom (
	clk,
	rst_n,
	wr_en,
	wr_priv,
	wr_engine,
	wr_data,
	params
);
	localparam [31:0] mom_pkg_ENG_N = 5;
	parameter [31:0] NENG = mom_pkg_ENG_N;
	input wire clk;
	input wire rst_n;
	input wire wr_en;
	input wire wr_priv;
	input wire [2:0] wr_engine;
	localparam [31:0] mom_pkg_EPARAM_W = 43;
	input wire [42:0] wr_data;
	output wire [(NENG * 43) - 1:0] params;
	localparam [42:0] DEF_CPU = 43'h00001283fff;
	localparam [42:0] DEF_SIMD = 43'h180420a3e3e;
	localparam [42:0] DEF_TPU = 43'h38202810618;
	localparam [42:0] DEF_NTT = 43'h28102044860;
	localparam [42:0] DEF_CRYPTO = 43'h20082020980;
	localparam [42:0] DEF_GPU = 43'h2040108080e;
	reg [42:0] row [0:NENG - 1];
	localparam signed [31:0] GPU_ROW = (NENG > 32'sd5 ? 32'sd5 : 0);
	generate
		if (NENG > 6) begin : g_too_many_slots
			mom_param_rom_supports_at_most_six_slots u_bad();
		end
	endgenerate
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			row[3'd0] <= DEF_CPU;
			row[3'd1] <= DEF_SIMD;
			row[3'd2] <= DEF_TPU;
			row[3'd3] <= DEF_NTT;
			row[3'd4] <= DEF_CRYPTO;
			if (NENG > 32'sd5)
				row[GPU_ROW] <= DEF_GPU;
		end
		else if ((wr_en && wr_priv) && ({29'd0, wr_engine} < NENG))
			row[wr_engine] <= wr_data;
	genvar _gv_e_2;
	function automatic [42:0] sv2v_cast_43;
		input reg [42:0] inp;
		sv2v_cast_43 = inp;
	endfunction
	generate
		for (_gv_e_2 = 0; _gv_e_2 < NENG; _gv_e_2 = _gv_e_2 + 1) begin : g_unpack
			localparam e = _gv_e_2;
			assign params[e * 43+:43] = sv2v_cast_43(row[e]);
		end
	endgenerate
endmodule
`default_nettype wire
`default_nettype none
module mom_scoreboard (
	clk,
	rst_n,
	disp_valid,
	disp_ready,
	disp_engine,
	disp_opclass,
	disp_t_pred,
	disp_tag,
	comp_valid,
	comp_tag,
	cal_valid,
	cal_engine,
	cal_opclass,
	cal_t_measured,
	cal_t_predicted,
	queue_depth,
	engine_full,
	fence_tag,
	fence_busy,
	err_stale_comp,
	tag_busy_vec
);
	reg _sv2v_0;
	localparam [31:0] mom_pkg_ENG_N = 5;
	parameter [31:0] NENG = mom_pkg_ENG_N;
	parameter [31:0] NTAG = 16;
	parameter [31:0] QMAX = 8;
	input wire clk;
	input wire rst_n;
	input wire disp_valid;
	output wire disp_ready;
	input wire [2:0] disp_engine;
	input wire [3:0] disp_opclass;
	localparam [31:0] mom_pkg_COST_W = 32;
	input wire [31:0] disp_t_pred;
	output wire [3:0] disp_tag;
	input wire comp_valid;
	input wire [3:0] comp_tag;
	output reg cal_valid;
	output reg [2:0] cal_engine;
	output reg [3:0] cal_opclass;
	output reg [31:0] cal_t_measured;
	output reg [31:0] cal_t_predicted;
	output reg [(NENG * 8) - 1:0] queue_depth;
	output wire [NENG - 1:0] engine_full;
	input wire [3:0] fence_tag;
	output wire fence_busy;
	output reg err_stale_comp;
	output wire [NTAG - 1:0] tag_busy_vec;
	reg [31:0] now;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			now <= {mom_pkg_COST_W {1'b0}};
		else
			now <= now + 32'd1;
	reg busy [0:NTAG - 1];
	reg [2:0] t_eng [0:NTAG - 1];
	reg [3:0] t_opc [0:NTAG - 1];
	reg [31:0] t_start [0:NTAG - 1];
	reg [31:0] t_pred [0:NTAG - 1];
	genvar _gv_t_1;
	generate
		for (_gv_t_1 = 0; _gv_t_1 < NTAG; _gv_t_1 = _gv_t_1 + 1) begin : g_busyvec
			localparam t = _gv_t_1;
			assign tag_busy_vec[t] = busy[t];
		end
	endgenerate
	localparam [31:0] TIW = (NTAG > 1 ? $clog2(NTAG) : 1);
	reg [3:0] free_tag;
	reg [TIW - 1:0] free_i;
	reg have_free;
	always @(*) begin
		if (_sv2v_0)
			;
		free_i = {TIW {1'b0}};
		free_tag = 4'd0;
		have_free = 1'b0;
		begin : sv2v_autoblock_1
			reg signed [31:0] t;
			for (t = NTAG - 1; t >= 0; t = t - 1)
				if (!busy[t]) begin
					free_i = t[TIW - 1:0];
					free_tag = t[3:0];
					have_free = 1'b1;
				end
		end
	end
	wire disp_engine_ok = {29'd0, disp_engine} < NENG;
	wire comp_tag_ok = {28'd0, comp_tag} < NTAG;
	wire [TIW - 1:0] comp_i = comp_tag[TIW - 1:0];
	wire [TIW - 1:0] fence_i = fence_tag[TIW - 1:0];
	wire engine_has_room = disp_engine_ok && !engine_full[disp_engine];
	assign disp_ready = have_free && engine_has_room;
	assign disp_tag = free_tag;
	wire do_disp = disp_valid && disp_ready;
	wire do_comp = (comp_valid && comp_tag_ok) && busy[comp_i];
	wire stale_comp = comp_valid && (!comp_tag_ok || !busy[comp_i]);
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			err_stale_comp <= 1'b0;
		else
			err_stale_comp <= stale_comp;
	genvar _gv_e_3;
	function automatic signed [2:0] sv2v_cast_3_signed;
		input reg signed [2:0] inp;
		sv2v_cast_3_signed = inp;
	endfunction
	generate
		for (_gv_e_3 = 0; _gv_e_3 < NENG; _gv_e_3 = _gv_e_3 + 1) begin : g_queue
			localparam e = _gv_e_3;
			wire inc = do_disp && (disp_engine == sv2v_cast_3_signed(e));
			wire dec = do_comp && (t_eng[comp_i] == sv2v_cast_3_signed(e));
			always @(posedge clk or negedge rst_n)
				if (!rst_n)
					queue_depth[e * 8+:8] <= 8'd0;
				else if (inc && !dec)
					queue_depth[e * 8+:8] <= queue_depth[e * 8+:8] + 8'd1;
				else if ((dec && !inc) && (queue_depth[e * 8+:8] != 8'd0))
					queue_depth[e * 8+:8] <= queue_depth[e * 8+:8] - 8'd1;
			assign engine_full[e] = {24'd0, queue_depth[e * 8+:8]} >= QMAX;
		end
	endgenerate
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin : sv2v_autoblock_2
			reg signed [31:0] t;
			for (t = 0; t < NTAG; t = t + 1)
				begin
					busy[t] <= 1'b0;
					t_eng[t] <= 3'd0;
					t_opc[t] <= 4'd0;
					t_start[t] <= {mom_pkg_COST_W {1'b0}};
					t_pred[t] <= {mom_pkg_COST_W {1'b0}};
				end
		end
		else begin
			if (do_disp) begin
				busy[free_i] <= 1'b1;
				t_eng[free_i] <= disp_engine;
				t_opc[free_i] <= disp_opclass;
				t_start[free_i] <= now;
				t_pred[free_i] <= disp_t_pred;
			end
			if (do_comp)
				busy[comp_i] <= 1'b0;
		end
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			cal_valid <= 1'b0;
		else begin
			cal_valid <= do_comp;
			cal_engine <= t_eng[comp_i];
			cal_opclass <= t_opc[comp_i];
			cal_t_measured <= now - t_start[comp_i];
			cal_t_predicted <= t_pred[comp_i];
		end
	assign fence_busy = ({28'd0, fence_tag} < NTAG ? busy[fence_i] : 1'b0);
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module mom_select (
	cost,
	valid,
	capable,
	sel_engine,
	sel_cost,
	any_valid,
	any_capable,
	sel_margin
);
	reg _sv2v_0;
	localparam [31:0] mom_pkg_ENG_N = 5;
	parameter [31:0] NENG = mom_pkg_ENG_N;
	parameter [0:0] WANT_MARGIN = 1;
	localparam [31:0] mom_pkg_COST_W = 32;
	input wire [(NENG * mom_pkg_COST_W) - 1:0] cost;
	input wire [NENG - 1:0] valid;
	input wire [NENG - 1:0] capable;
	output reg [2:0] sel_engine;
	output reg [31:0] sel_cost;
	output reg any_valid;
	output reg any_capable;
	output reg [31:0] sel_margin;
	localparam [31:0] PW = 36;
	wire [35:0] lane [0:NENG - 1];
	genvar _gv_e_4;
	function automatic signed [2:0] sv2v_cast_3_signed;
		input reg signed [2:0] inp;
		sv2v_cast_3_signed = inp;
	endfunction
	generate
		for (_gv_e_4 = 0; _gv_e_4 < NENG; _gv_e_4 = _gv_e_4 + 1) begin : g_pack
			localparam e = _gv_e_4;
			assign lane[e] = {~valid[e], cost[e * mom_pkg_COST_W+:mom_pkg_COST_W], sv2v_cast_3_signed(e)};
		end
	endgenerate
	function automatic [35:0] pick;
		input reg [35:0] a;
		input reg [35:0] b;
		pick = (a[35:3] <= b[35:3] ? a : b);
	endfunction
	wire [35:0] l1_a = pick(lane[0], lane[1]);
	wire [35:0] l1_b = pick(lane[2], lane[3]);
	wire [35:0] l2 = pick(l1_a, l1_b);
	wire [35:0] best_chain [0:NENG - 5];
	assign best_chain[0] = pick(l2, lane[4]);
	genvar _gv_e_5;
	generate
		for (_gv_e_5 = 5; _gv_e_5 < NENG; _gv_e_5 = _gv_e_5 + 1) begin : g_more
			localparam e = _gv_e_5;
			assign best_chain[e - 4] = pick(best_chain[e - 5], lane[e]);
		end
	endgenerate
	wire [35:0] best = best_chain[NENG - 5];
	wire [35:0] snd;
	generate
		if (WANT_MARGIN) begin : g_margin
			wire [35:0] lane2 [0:NENG - 1];
			genvar _gv_e_6;
			for (_gv_e_6 = 0; _gv_e_6 < NENG; _gv_e_6 = _gv_e_6 + 1) begin : g_pack2
				localparam e = _gv_e_6;
				assign lane2[e] = (sv2v_cast_3_signed(e) == best[2:0] ? {1'b1, cost[e * mom_pkg_COST_W+:mom_pkg_COST_W], sv2v_cast_3_signed(e)} : lane[e]);
			end
			wire [35:0] m1_a = pick(lane2[0], lane2[1]);
			wire [35:0] m1_b = pick(lane2[2], lane2[3]);
			wire [35:0] m2 = pick(m1_a, m1_b);
			wire [35:0] snd_chain [0:NENG - 5];
			assign snd_chain[0] = pick(m2, lane2[4]);
			genvar _gv_e_7;
			for (_gv_e_7 = 5; _gv_e_7 < NENG; _gv_e_7 = _gv_e_7 + 1) begin : g_more2
				localparam e = _gv_e_7;
				assign snd_chain[e - 4] = pick(snd_chain[e - 5], lane2[e]);
			end
			assign snd = snd_chain[NENG - 5];
		end
		else begin : g_no_margin
			assign snd = {1'b1, {mom_pkg_COST_W {1'b0}}, 3'd0};
		end
	endgenerate
	always @(*) begin
		if (_sv2v_0)
			;
		any_valid = |valid;
		any_capable = |capable;
		sel_engine = best[2:0];
		sel_cost = best[34:3];
		sel_margin = (snd[35] || !any_valid ? {mom_pkg_COST_W {1'b0}} : (snd[34:3] >= best[34:3] ? snd[34:3] - best[34:3] : {mom_pkg_COST_W {1'b0}}));
	end
	wire _unused_ok = &{1'b0, best[35], snd[2:0]};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module mom_top (
	clk,
	rst_n,
	wd_valid,
	wd_ready,
	wd,
	eng_elig,
	disp_valid,
	disp_accept,
	disp_engine,
	disp_tag,
	disp_wd,
	comp_valid,
	comp_tag,
	fence_tag,
	fence_busy,
	csr_wr,
	csr_priv,
	csr_engine,
	csr_data,
	csr_bw_dma_log2,
	csr_eps_mem,
	csr_e_shift,
	csr_cal_freeze,
	csr_cal_reset,
	err_unsupported,
	err_tag,
	err_stale_comp,
	obs_margin,
	obs_cal_updates,
	obs_tag_busy
);
	localparam [31:0] mom_pkg_ENG_N = 5;
	parameter [31:0] NENG = mom_pkg_ENG_N;
	parameter [0:0] COST_SHARED = 1'b1;
	parameter [31:0] NTAG = 16;
	parameter [31:0] QMAX = 8;
	input wire clk;
	input wire rst_n;
	input wire wd_valid;
	output wire wd_ready;
	input wire [127:0] wd;
	input wire [NENG - 1:0] eng_elig;
	output wire disp_valid;
	input wire disp_accept;
	output wire [2:0] disp_engine;
	output wire [3:0] disp_tag;
	output wire [127:0] disp_wd;
	input wire comp_valid;
	input wire [3:0] comp_tag;
	input wire [3:0] fence_tag;
	output wire fence_busy;
	input wire csr_wr;
	input wire csr_priv;
	input wire [2:0] csr_engine;
	localparam [31:0] mom_pkg_EPARAM_W = 43;
	input wire [42:0] csr_data;
	input wire [3:0] csr_bw_dma_log2;
	input wire [3:0] csr_eps_mem;
	input wire [3:0] csr_e_shift;
	input wire csr_cal_freeze;
	input wire csr_cal_reset;
	output reg err_unsupported;
	output reg [7:0] err_tag;
	output wire err_stale_comp;
	localparam [31:0] mom_pkg_COST_W = 32;
	output wire [31:0] obs_margin;
	output wire [15:0] obs_cal_updates;
	output wire [NTAG - 1:0] obs_tag_busy;
	wire f_valid;
	wire f_ready;
	wire [127:0] f_wd;
	wire [7:0] f_lg_w;
	wire [7:0] f_lg_q;
	wire signed [8:0] f_lg_i;
	mom_features u_feat(
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(wd_valid),
		.in_ready(wd_ready),
		.in_wd(wd),
		.out_valid(f_valid),
		.out_ready(f_ready),
		.out_wd(f_wd),
		.out_log2_w(f_lg_w),
		.out_log2_q(f_lg_q),
		.out_log2_i(f_lg_i)
	);
	wire [(NENG * 43) - 1:0] params;
	mom_param_rom #(.NENG(NENG)) u_prom(
		.clk(clk),
		.rst_n(rst_n),
		.wr_en(csr_wr),
		.wr_priv(csr_priv),
		.wr_engine(csr_engine),
		.wr_data(csr_data),
		.params(params)
	);
	wire [(NENG * 8) - 1:0] queue_depth;
	wire [NENG - 1:0] engine_full;
	wire cal_valid;
	wire [2:0] cal_engine;
	wire [3:0] cal_opclass;
	wire [31:0] cal_t_meas;
	wire [31:0] cal_t_pred;
	wire [(NENG * 8) - 1:0] k_cal;
	wire cal_last_dir;
	mom_calibrate #(.NENG(NENG)) u_cal(
		.clk(clk),
		.rst_n(rst_n),
		.freeze(csr_cal_freeze),
		.reset_factors(csr_cal_reset),
		.rd_opclass(f_wd[127-:4]),
		.rd_k(k_cal),
		.upd_valid(cal_valid),
		.upd_engine(cal_engine),
		.upd_opclass(cal_opclass),
		.upd_t_measured(cal_t_meas),
		.upd_t_predicted(cal_t_pred),
		.upd_count(obs_cal_updates),
		.last_dir(cal_last_dir)
	);
	wire [(NENG * mom_pkg_COST_W) - 1:0] cost;
	wire [(NENG * mom_pkg_COST_W) - 1:0] t_pred;
	wire [NENG - 1:0] cvalid;
	wire [NENG - 1:0] ccapable;
	wire eval_done;
	reg eval_busy;
	wire lane_we;
	wire [2:0] lane_idx;
	wire [31:0] lane_cost;
	wire [31:0] lane_tpred;
	wire lane_valid;
	wire lane_capable;
	reg a_valid;
	wire c_ready;
	reg c_valid;
	wire c_accept = !c_valid || c_ready;
	wire a_adv = !a_valid || c_accept;
	function automatic [3:0] mom_pkg_lambda_sh_of;
		input reg [1:0] h;
		case (h)
			2'd0: mom_pkg_lambda_sh_of = 4'b0000;
			2'd1: mom_pkg_lambda_sh_of = 4'b1000;
			2'd2: mom_pkg_lambda_sh_of = 4'b1010;
			2'd3: mom_pkg_lambda_sh_of = 4'b1100;
			default: mom_pkg_lambda_sh_of = 4'b1000;
		endcase
	endfunction
	function automatic [2:0] sv2v_cast_3;
		input reg [2:0] inp;
		sv2v_cast_3 = inp;
	endfunction
	generate
		if (!COST_SHARED) begin : g_parallel
			genvar _gv_e_8;
			for (_gv_e_8 = 0; _gv_e_8 < NENG; _gv_e_8 = _gv_e_8 + 1) begin : g_cost
				localparam e = _gv_e_8;
				mom_cost_engine #(.ENGINE_ID(sv2v_cast_3(e))) u_ce(
					.clk(clk),
					.rst_n(rst_n),
					.adv(a_adv),
					.log2_w(f_lg_w),
					.bytes_q(f_wd[68-:24]),
					.log2_i(f_lg_i),
					.dtype(f_wd[123-:3]),
					.op_class(f_wd[127-:4]),
					.lat_hint(f_wd[120-:2]),
					.lambda_sh(mom_pkg_lambda_sh_of(f_wd[118-:2])),
					.param(params[e * 43+:43]),
					.k_cal(k_cal[e * 8+:8]),
					.queue_depth(queue_depth[e * 8+:8]),
					.engine_busy_full(1'b0),
					.bw_dma_log2(csr_bw_dma_log2),
					.eps_mem(csr_eps_mem),
					.e_shift(csr_e_shift),
					.cost(cost[e * mom_pkg_COST_W+:mom_pkg_COST_W]),
					.t_pred(t_pred[e * mom_pkg_COST_W+:mom_pkg_COST_W]),
					.valid(cvalid[e]),
					.capable(ccapable[e])
				);
			end
			assign eval_done = 1'b0;
			wire [1:1] sv2v_tmp_74BE0;
			assign sv2v_tmp_74BE0 = 1'b0;
			always @(*) eval_busy = sv2v_tmp_74BE0;
			assign lane_we = 1'b0;
			assign lane_idx = 3'd0;
			assign lane_cost = {mom_pkg_COST_W {1'b0}};
			assign lane_tpred = {mom_pkg_COST_W {1'b0}};
			assign lane_valid = 1'b0;
			assign lane_capable = 1'b0;
		end
		else begin : g_shared
			reg [2:0] idx;
			reg phase;
			wire last = ({29'd0, idx} == (NENG - 1)) && phase;
			always @(posedge clk or negedge rst_n)
				if (!rst_n) begin
					idx <= 3'd0;
					phase <= 1'b0;
					eval_busy <= 1'b0;
				end
				else if (!eval_busy) begin
					if (f_valid && (!c_valid || c_ready)) begin
						eval_busy <= 1'b1;
						idx <= 3'd0;
						phase <= 1'b0;
					end
				end
				else if (last) begin
					eval_busy <= 1'b0;
					idx <= 3'd0;
					phase <= 1'b0;
				end
				else if (phase) begin
					phase <= 1'b0;
					idx <= idx + 3'd1;
				end
				else
					phase <= 1'b1;
			assign eval_done = eval_busy && last;
			wire [31:0] s_cost;
			wire [31:0] s_tpred;
			wire s_valid;
			wire s_capable;
			mom_cost_engine #(.ENGINE_ID(3'd0)) u_ce(
				.clk(clk),
				.rst_n(rst_n),
				.adv(eval_busy && !phase),
				.log2_w(f_lg_w),
				.bytes_q(f_wd[68-:24]),
				.log2_i(f_lg_i),
				.dtype(f_wd[123-:3]),
				.op_class(f_wd[127-:4]),
				.lat_hint(f_wd[120-:2]),
				.lambda_sh(mom_pkg_lambda_sh_of(f_wd[118-:2])),
				.param(params[idx * 43+:43]),
				.k_cal(k_cal[idx * 8+:8]),
				.queue_depth(queue_depth[idx * 8+:8]),
				.engine_busy_full(1'b0),
				.bw_dma_log2(csr_bw_dma_log2),
				.eps_mem(csr_eps_mem),
				.e_shift(csr_e_shift),
				.cost(s_cost),
				.t_pred(s_tpred),
				.valid(s_valid),
				.capable(s_capable)
			);
			assign lane_we = eval_busy && phase;
			assign lane_idx = idx;
			assign lane_cost = s_cost;
			assign lane_tpred = s_tpred;
			assign lane_valid = s_valid;
			assign lane_capable = s_capable;
			assign cost = {NENG * mom_pkg_COST_W {1'b0}};
			assign t_pred = {NENG * mom_pkg_COST_W {1'b0}};
			assign cvalid = {NENG {1'b0}};
			assign ccapable = {NENG {1'b0}};
		end
	endgenerate
	reg [(NENG * mom_pkg_COST_W) - 1:0] cost_q;
	reg [(NENG * mom_pkg_COST_W) - 1:0] t_pred_q;
	reg [NENG - 1:0] ccapable_q;
	reg [127:0] c_wd;
	reg [127:0] a_wd;
	wire a_load = (COST_SHARED ? 1'b0 : a_adv && f_valid);
	wire a_clear = (COST_SHARED ? 1'b0 : a_adv && !f_valid);
	localparam [31:0] mom_pkg_WD_W = 128;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			a_valid <= 1'b0;
			a_wd <= {mom_pkg_WD_W {1'b0}};
		end
		else if (a_load) begin
			a_valid <= 1'b1;
			a_wd <= f_wd;
		end
		else if (a_clear)
			a_valid <= 1'b0;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			c_valid <= 1'b0;
			cost_q <= {NENG * mom_pkg_COST_W {1'b0}};
			t_pred_q <= {NENG * mom_pkg_COST_W {1'b0}};
			ccapable_q <= {NENG {1'b0}};
			c_wd <= {mom_pkg_WD_W {1'b0}};
		end
		else if (COST_SHARED) begin
			if (lane_we) begin
				cost_q[lane_idx * mom_pkg_COST_W+:mom_pkg_COST_W] <= lane_cost;
				t_pred_q[lane_idx * mom_pkg_COST_W+:mom_pkg_COST_W] <= lane_tpred;
				ccapable_q[lane_idx] <= lane_capable;
			end
			if (eval_done) begin
				c_valid <= 1'b1;
				c_wd <= f_wd;
			end
			else if (c_ready)
				c_valid <= 1'b0;
		end
		else if (c_accept) begin
			c_valid <= a_valid;
			if (a_valid) begin
				cost_q <= cost;
				t_pred_q <= t_pred;
				ccapable_q <= ccapable;
				c_wd <= a_wd;
			end
		end
	wire [2:0] sel_eng;
	wire [31:0] sel_cost;
	wire sel_ok;
	wire sel_capable;
	mom_select #(.NENG(NENG)) u_sel(
		.cost(cost_q),
		.valid((ccapable_q & ~engine_full) & eng_elig),
		.capable(ccapable_q & eng_elig),
		.sel_engine(sel_eng),
		.sel_cost(sel_cost),
		.any_valid(sel_ok),
		.any_capable(sel_capable),
		.sel_margin(obs_margin)
	);
	wire unsupported = c_valid && !sel_capable;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			err_unsupported <= 1'b0;
			err_tag <= 8'd0;
		end
		else begin
			err_unsupported <= unsupported;
			if (unsupported)
				err_tag <= c_wd[42-:8];
		end
	wire sb_ready;
	mom_scoreboard #(
		.NENG(NENG),
		.NTAG(NTAG),
		.QMAX(QMAX)
	) u_sb(
		.clk(clk),
		.rst_n(rst_n),
		.disp_valid((c_valid && sel_ok) && disp_accept),
		.disp_ready(sb_ready),
		.disp_engine(sel_eng),
		.disp_opclass(c_wd[127-:4]),
		.disp_t_pred(t_pred_q[sel_eng * mom_pkg_COST_W+:mom_pkg_COST_W]),
		.disp_tag(disp_tag),
		.comp_valid(comp_valid),
		.comp_tag(comp_tag),
		.cal_valid(cal_valid),
		.cal_engine(cal_engine),
		.cal_opclass(cal_opclass),
		.cal_t_measured(cal_t_meas),
		.cal_t_predicted(cal_t_pred),
		.queue_depth(queue_depth),
		.engine_full(engine_full),
		.fence_tag(fence_tag),
		.fence_busy(fence_busy),
		.err_stale_comp(err_stale_comp),
		.tag_busy_vec(obs_tag_busy)
	);
	assign disp_valid = (c_valid && sel_ok) && sb_ready;
	assign disp_engine = sel_eng;
	assign disp_wd = c_wd;
	assign c_ready = (disp_valid && disp_accept) || unsupported;
	assign f_ready = (COST_SHARED ? eval_done : a_adv);
	wire _unused_ok = &{1'b0, f_lg_q, sel_cost, cal_last_dir, cvalid, lane_valid};
endmodule
`default_nettype wire
`default_nettype none
module mom_xbar (
	clk,
	rst_n,
	disp_valid,
	disp_accept,
	disp_engine,
	disp_tag,
	disp_wd,
	comp_valid,
	comp_tag,
	eng_valid,
	eng_ready,
	eng_wd,
	eng_tag,
	eng_done,
	eng_done_tag,
	eng_busy,
	err_bad_engine,
	err_done_unknown
);
	reg _sv2v_0;
	parameter signed [31:0] NENG = 5;
	parameter signed [31:0] NTAG = 8;
	parameter signed [31:0] WD_W = 128;
	parameter signed [31:0] TAGW = 4;
	parameter signed [31:0] ENGW = 3;
	input wire clk;
	input wire rst_n;
	input wire disp_valid;
	output wire disp_accept;
	input wire [ENGW - 1:0] disp_engine;
	input wire [TAGW - 1:0] disp_tag;
	input wire [WD_W - 1:0] disp_wd;
	output wire comp_valid;
	output wire [TAGW - 1:0] comp_tag;
	output reg [NENG - 1:0] eng_valid;
	input wire [NENG - 1:0] eng_ready;
	output wire [WD_W - 1:0] eng_wd;
	output reg [(NENG * TAGW) - 1:0] eng_tag;
	input wire [NENG - 1:0] eng_done;
	input wire [(NENG * TAGW) - 1:0] eng_done_tag;
	output wire [NENG - 1:0] eng_busy;
	output reg err_bad_engine;
	output reg err_done_unknown;
	reg [NENG - 1:0] busy_q;
	reg [NENG - 1:0] pend_q;
	reg [TAGW - 1:0] tag_q [0:NENG - 1];
	reg [ENGW - 1:0] rr_ptr;
	assign eng_busy = busy_q;
	function automatic signed [((ENGW + 0) >= 0 ? ENGW + 1 : 1 - (ENGW + 0)) - 1:0] sv2v_cast_63872_signed;
		input reg signed [((ENGW + 0) >= 0 ? ENGW + 1 : 1 - (ENGW + 0)) - 1:0] inp;
		sv2v_cast_63872_signed = inp;
	endfunction
	wire eng_in_range = {1'b0, disp_engine} < sv2v_cast_63872_signed(NENG);
	wire in_range = eng_in_range;
	generate
		if (NENG > (1 << ENGW)) begin : g_bad_param
			mom_xbar_NENG_needs_a_wider_ENGW u_stop();
		end
	endgenerate
	wire target_free = (in_range && !busy_q[disp_engine]) && eng_ready[disp_engine];
	wire fwd = (rst_n && disp_valid) && target_free;
	wire bad = (rst_n && disp_valid) && !in_range;
	always @(*) begin
		if (_sv2v_0)
			;
		eng_valid = 1'sb0;
		if (fwd)
			eng_valid[disp_engine] = 1'b1;
	end
	assign eng_wd = disp_wd;
	assign disp_accept = fwd || bad;
	function automatic signed [ENGW - 1:0] sv2v_cast_966DA_signed;
		input reg signed [ENGW - 1:0] inp;
		sv2v_cast_966DA_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] e;
			for (e = 0; e < NENG; e = e + 1)
				begin
					eng_tag[e * TAGW+:TAGW] = tag_q[e];
					if (fwd && (sv2v_cast_966DA_signed(e) == disp_engine))
						eng_tag[e * TAGW+:TAGW] = disp_tag;
				end
		end
	end
	reg [NENG - 1:0] done_ok;
	always @(*) begin : sv2v_autoblock_2
		reg signed [31:0] e;
		if (_sv2v_0)
			;
		for (e = 0; e < NENG; e = e + 1)
			done_ok[e] = ((eng_done[e] && busy_q[e]) && !pend_q[e]) && (eng_done_tag[e * TAGW+:TAGW] == tag_q[e]);
	end
	wire [NENG - 1:0] done_bad = eng_done & ~done_ok;
	wire [NENG - 1:0] ready_set = pend_q | done_ok;
	reg take_any;
	integer take_i;
	integer scan_i;
	integer scan_e;
	wire [ENGW - 1:0] take_e = take_i[ENGW - 1:0];
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		take_any = 1'b0;
		take_i = 0;
		for (scan_i = NENG - 1; scan_i >= 0; scan_i = scan_i - 1)
			begin
				scan_e = scan_i + sv2v_cast_32_signed(rr_ptr);
				if (scan_e >= NENG)
					scan_e = scan_e - NENG;
				if (ready_set[scan_e]) begin
					take_any = 1'b1;
					take_i = scan_e;
				end
			end
	end
	assign comp_valid = take_any;
	wire _unused_take = &{1'b0, take_i[31:ENGW], NTAG[0]};
	assign comp_tag = tag_q[take_e];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			busy_q <= 1'sb0;
			pend_q <= 1'sb0;
			rr_ptr <= 1'sb0;
			err_bad_engine <= 1'b0;
			err_done_unknown <= 1'b0;
			begin : sv2v_autoblock_3
				reg signed [31:0] e;
				for (e = 0; e < NENG; e = e + 1)
					tag_q[e] <= 1'sb0;
			end
		end
		else begin
			err_bad_engine <= bad;
			err_done_unknown <= |done_bad;
			if (fwd) begin
				busy_q[disp_engine] <= 1'b1;
				tag_q[disp_engine] <= disp_tag;
			end
			begin : sv2v_autoblock_4
				reg signed [31:0] e;
				for (e = 0; e < NENG; e = e + 1)
					begin
						if (done_ok[e])
							pend_q[e] <= 1'b1;
						if (take_any && (sv2v_cast_966DA_signed(e) == take_e)) begin
							pend_q[e] <= 1'b0;
							busy_q[e] <= 1'b0;
						end
					end
			end
			if (take_any)
				rr_ptr <= (take_e == sv2v_cast_966DA_signed(NENG - 1) ? {ENGW {1'sb0}} : take_e + sv2v_cast_966DA_signed(1));
		end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
`default_nettype wire
`default_nettype none
module tpu_array (
	clk,
	rst_n,
	en,
	clr,
	shift_en,
	a_west,
	b_north,
	acc_south
);
	localparam [31:0] tpu_pkg_N_PE = 4;
	parameter [31:0] N = tpu_pkg_N_PE;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire clr;
	input wire shift_en;
	localparam [31:0] tpu_pkg_AW = 8;
	input wire signed [(N * tpu_pkg_AW) - 1:0] a_west;
	input wire signed [(N * tpu_pkg_AW) - 1:0] b_north;
	localparam [31:0] tpu_pkg_ACCW = 32;
	output wire signed [(N * tpu_pkg_ACCW) - 1:0] acc_south;
	wire signed [7:0] a_h [0:N - 1][0:N + 0];
	wire signed [7:0] b_v [0:N + 0][0:N - 1];
	wire signed [31:0] acc_v [0:N + 0][0:N - 1];
	genvar _gv_r_1;
	genvar _gv_c_1;
	generate
		for (_gv_r_1 = 0; _gv_r_1 < N; _gv_r_1 = _gv_r_1 + 1) begin : g_west
			localparam r = _gv_r_1;
			assign a_h[r][0] = a_west[((N - 1) - r) * tpu_pkg_AW+:tpu_pkg_AW];
		end
		for (_gv_c_1 = 0; _gv_c_1 < N; _gv_c_1 = _gv_c_1 + 1) begin : g_north
			localparam c = _gv_c_1;
			assign b_v[0][c] = b_north[((N - 1) - c) * tpu_pkg_AW+:tpu_pkg_AW];
			assign acc_v[0][c] = 1'sb0;
		end
		for (_gv_r_1 = 0; _gv_r_1 < N; _gv_r_1 = _gv_r_1 + 1) begin : g_row
			localparam r = _gv_r_1;
			for (_gv_c_1 = 0; _gv_c_1 < N; _gv_c_1 = _gv_c_1 + 1) begin : g_col
				localparam c = _gv_c_1;
				tpu_pe u_pe(
					.clk(clk),
					.rst_n(rst_n),
					.en(en),
					.clr(clr),
					.shift_en(shift_en),
					.a_in(a_h[r][c]),
					.b_in(b_v[r][c]),
					.acc_in(acc_v[r][c]),
					.a_out(a_h[r][c + 1]),
					.b_out(b_v[r + 1][c]),
					.acc_out(acc_v[r + 1][c])
				);
			end
		end
		for (_gv_c_1 = 0; _gv_c_1 < N; _gv_c_1 = _gv_c_1 + 1) begin : g_south
			localparam c = _gv_c_1;
			assign acc_south[((N - 1) - c) * tpu_pkg_ACCW+:tpu_pkg_ACCW] = acc_v[N][c];
		end
	endgenerate
endmodule
`default_nettype wire
`default_nettype none
module tpu_ctrl (
	clk,
	rst_n,
	start,
	dim_m,
	dim_n,
	dim_k,
	opclass_ok,
	dtype_ok,
	op_ready,
	op_valid,
	arr_clr,
	arr_en,
	feed_valid,
	arr_shift,
	feed_flush,
	row_valid,
	row_last,
	drain_busy,
	done,
	status,
	busy
);
	reg _sv2v_0;
	localparam [31:0] tpu_pkg_N_PE = 4;
	parameter [31:0] N = tpu_pkg_N_PE;
	input wire clk;
	input wire rst_n;
	input wire start;
	localparam [31:0] tpu_pkg_KW = 16;
	input wire [15:0] dim_m;
	input wire [15:0] dim_n;
	input wire [15:0] dim_k;
	input wire opclass_ok;
	input wire dtype_ok;
	output reg op_ready;
	input wire op_valid;
	output reg arr_clr;
	output reg arr_en;
	output reg feed_valid;
	output reg arr_shift;
	output reg feed_flush;
	output reg row_valid;
	output reg row_last;
	input wire drain_busy;
	output reg done;
	output reg [1:0] status;
	output reg busy;
	reg [2:0] st_q;
	reg [15:0] k_left_q;
	reg [$clog2(2 * N) - 1:0] flush_q;
	reg [$clog2(N + 1) - 1:0] row_q;
	reg [1:0] status_q;
	function automatic [15:0] sv2v_cast_9432F;
		input reg [15:0] inp;
		sv2v_cast_9432F = inp;
	endfunction
	wire dims_ok = ((((dim_m != 0) && (dim_n != 0)) && (dim_k != 0)) && (dim_m <= sv2v_cast_9432F(N))) && (dim_n <= sv2v_cast_9432F(N));
	wire job_ok = (opclass_ok && dtype_ok) && dims_ok;
	wire [1:0] why = (!opclass_ok ? 2'd1 : (!dtype_ok ? 2'd2 : 2'd3));
	function automatic signed [15:0] sv2v_cast_9432F_signed;
		input reg signed [15:0] inp;
		sv2v_cast_9432F_signed = inp;
	endfunction
	function automatic [$clog2(2 * N) - 1:0] sv2v_cast_CC80E;
		input reg [$clog2(2 * N) - 1:0] inp;
		sv2v_cast_CC80E = inp;
	endfunction
	function automatic [$clog2(N + 1) - 1:0] sv2v_cast_54CAC;
		input reg [$clog2(N + 1) - 1:0] inp;
		sv2v_cast_54CAC = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			st_q <= 3'd0;
			k_left_q <= 1'sb0;
			flush_q <= 1'sb0;
			row_q <= 1'sb0;
			status_q <= 2'd0;
		end
		else
			(* full_case, parallel_case *)
			case (st_q)
				3'd0:
					if (start) begin
						if (job_ok) begin
							st_q <= 3'd1;
							k_left_q <= dim_k;
							status_q <= 2'd0;
						end
						else begin
							st_q <= 3'd6;
							status_q <= why;
						end
					end
				3'd1: st_q <= 3'd2;
				3'd2:
					if (op_valid) begin
						if (k_left_q == sv2v_cast_9432F_signed(1)) begin
							st_q <= 3'd3;
							flush_q <= 1'sb0;
						end
						k_left_q <= k_left_q - sv2v_cast_9432F_signed(1);
					end
				3'd3:
					if (flush_q == sv2v_cast_CC80E((2 * N) - 3)) begin
						st_q <= 3'd4;
						row_q <= 1'sb0;
					end
					else
						flush_q <= flush_q + 1'b1;
				3'd4:
					if (!drain_busy) begin
						if (row_q == sv2v_cast_54CAC(N - 1))
							st_q <= 3'd5;
						else
							row_q <= row_q + 1'b1;
					end
				3'd5:
					if (!drain_busy)
						st_q <= 3'd6;
				3'd6: st_q <= 3'd0;
				default: st_q <= 3'd0;
			endcase
	always @(*) begin
		if (_sv2v_0)
			;
		arr_clr = st_q == 3'd1;
		arr_en = ((st_q == 3'd2) && op_valid) || (st_q == 3'd3);
		feed_valid = (st_q == 3'd2) && op_valid;
		arr_shift = (st_q == 3'd4) && !drain_busy;
		feed_flush = st_q == 3'd1;
		op_ready = st_q == 3'd2;
		row_valid = (st_q == 3'd4) && !drain_busy;
		row_last = row_valid && (row_q == sv2v_cast_54CAC(N - 1));
		done = st_q == 3'd6;
		status = status_q;
		busy = st_q != 3'd0;
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module tpu_drain (
	clk,
	rst_n,
	row_valid,
	row,
	row_last,
	res_valid,
	res_data,
	res_last,
	busy
);
	localparam [31:0] tpu_pkg_N_PE = 4;
	parameter [31:0] N = tpu_pkg_N_PE;
	input wire clk;
	input wire rst_n;
	input wire row_valid;
	localparam [31:0] tpu_pkg_ACCW = 32;
	input wire [(N * tpu_pkg_ACCW) - 1:0] row;
	input wire row_last;
	output wire res_valid;
	output wire signed [31:0] res_data;
	output wire res_last;
	output wire busy;
	reg [(N * tpu_pkg_ACCW) - 1:0] buf_q;
	reg [$clog2(N + 1) - 1:0] idx_q;
	reg last_q;
	reg active_q;
	function automatic [$clog2(N + 1) - 1:0] sv2v_cast_54CAC;
		input reg [$clog2(N + 1) - 1:0] inp;
		sv2v_cast_54CAC = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			idx_q <= 1'sb0;
			last_q <= 1'b0;
			active_q <= 1'b0;
			buf_q <= 1'sb0;
		end
		else if (row_valid && !active_q) begin
			buf_q <= row;
			idx_q <= 1'sb0;
			last_q <= row_last;
			active_q <= 1'b1;
		end
		else if (active_q) begin
			if (idx_q == sv2v_cast_54CAC(N - 1))
				active_q <= 1'b0;
			else
				idx_q <= idx_q + 1'b1;
		end
	assign res_valid = active_q;
	assign res_data = buf_q[idx_q * tpu_pkg_ACCW+:tpu_pkg_ACCW];
	assign res_last = (active_q && last_q) && (idx_q == sv2v_cast_54CAC(N - 1));
	assign busy = active_q;
endmodule
`default_nettype wire
`default_nettype none
module tpu_feeder (
	clk,
	rst_n,
	flush,
	step,
	in_valid,
	a_slice,
	b_slice,
	a_skew,
	b_skew
);
	localparam [31:0] tpu_pkg_N_PE = 4;
	parameter [31:0] N = tpu_pkg_N_PE;
	input wire clk;
	input wire rst_n;
	input wire flush;
	input wire step;
	input wire in_valid;
	localparam [31:0] tpu_pkg_AW = 8;
	input wire signed [(N * tpu_pkg_AW) - 1:0] a_slice;
	input wire signed [(N * tpu_pkg_AW) - 1:0] b_slice;
	output wire signed [(N * tpu_pkg_AW) - 1:0] a_skew;
	output wire signed [(N * tpu_pkg_AW) - 1:0] b_skew;
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < N; _gv_i_1 = _gv_i_1 + 1) begin : g_lane
			localparam i = _gv_i_1;
			if (i == 0) begin : g_direct
				assign a_skew[(N - 1) * tpu_pkg_AW+:tpu_pkg_AW] = (in_valid ? a_slice[(N - 1) * tpu_pkg_AW+:tpu_pkg_AW] : {8 {1'sb0}});
				assign b_skew[(N - 1) * tpu_pkg_AW+:tpu_pkg_AW] = (in_valid ? b_slice[(N - 1) * tpu_pkg_AW+:tpu_pkg_AW] : {8 {1'sb0}});
			end
			else begin : g_delay
				reg [(i * tpu_pkg_AW) - 1:0] a_pipe;
				reg [(i * tpu_pkg_AW) - 1:0] b_pipe;
				wire [((i + 1) * tpu_pkg_AW) - 1:0] a_next = {a_pipe, (in_valid ? a_slice[((N - 1) - i) * tpu_pkg_AW+:tpu_pkg_AW] : {tpu_pkg_AW {1'b0}})};
				wire [((i + 1) * tpu_pkg_AW) - 1:0] b_next = {b_pipe, (in_valid ? b_slice[((N - 1) - i) * tpu_pkg_AW+:tpu_pkg_AW] : {tpu_pkg_AW {1'b0}})};
				wire _unused_top = &{1'b0, a_next[((i + 1) * tpu_pkg_AW) - 1:i * tpu_pkg_AW], b_next[((i + 1) * tpu_pkg_AW) - 1:i * tpu_pkg_AW]};
				always @(posedge clk or negedge rst_n)
					if (!rst_n) begin
						a_pipe <= 1'sb0;
						b_pipe <= 1'sb0;
					end
					else if (flush) begin
						a_pipe <= 1'sb0;
						b_pipe <= 1'sb0;
					end
					else if (step) begin
						a_pipe <= a_next[(i * tpu_pkg_AW) - 1:0];
						b_pipe <= b_next[(i * tpu_pkg_AW) - 1:0];
					end
				assign a_skew[((N - 1) - i) * tpu_pkg_AW+:tpu_pkg_AW] = a_pipe[(i * tpu_pkg_AW) - 1-:tpu_pkg_AW];
				assign b_skew[((N - 1) - i) * tpu_pkg_AW+:tpu_pkg_AW] = b_pipe[(i * tpu_pkg_AW) - 1-:tpu_pkg_AW];
			end
		end
	endgenerate
endmodule
`default_nettype wire
`default_nettype none
module tpu_pe (
	clk,
	rst_n,
	en,
	clr,
	shift_en,
	a_in,
	b_in,
	acc_in,
	a_out,
	b_out,
	acc_out
);
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire clr;
	input wire shift_en;
	localparam [31:0] tpu_pkg_AW = 8;
	input wire signed [7:0] a_in;
	input wire signed [7:0] b_in;
	localparam [31:0] tpu_pkg_ACCW = 32;
	input wire signed [31:0] acc_in;
	output reg signed [7:0] a_out;
	output reg signed [7:0] b_out;
	output wire signed [31:0] acc_out;
	reg signed [31:0] acc_q;
	wire signed [15:0] prod = a_in * b_in;
	function automatic signed [31:0] sv2v_cast_DEBC9_signed;
		input reg signed [31:0] inp;
		sv2v_cast_DEBC9_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			a_out <= 1'sb0;
			b_out <= 1'sb0;
			acc_q <= 1'sb0;
		end
		else begin
			if (en) begin
				a_out <= a_in;
				b_out <= b_in;
			end
			if (clr)
				acc_q <= 1'sb0;
			else if (shift_en)
				acc_q <= acc_in;
			else if (en)
				acc_q <= acc_q + sv2v_cast_DEBC9_signed(prod);
		end
	assign acc_out = acc_q;
endmodule
`default_nettype wire
`default_nettype none
module tpu_top (
	clk,
	rst_n,
	eng_valid,
	eng_ready,
	eng_wd,
	eng_tag,
	eng_done,
	eng_done_tag,
	op_ready,
	op_valid,
	op_a,
	op_b,
	res_valid,
	res_data,
	res_last,
	status
);
	reg _sv2v_0;
	localparam [31:0] tpu_pkg_N_PE = 4;
	parameter [31:0] N = tpu_pkg_N_PE;
	parameter [31:0] WD_W = 128;
	parameter [31:0] TAGW = 4;
	input wire clk;
	input wire rst_n;
	input wire eng_valid;
	output wire eng_ready;
	input wire [WD_W - 1:0] eng_wd;
	input wire [TAGW - 1:0] eng_tag;
	output wire eng_done;
	output wire [TAGW - 1:0] eng_done_tag;
	output wire op_ready;
	input wire op_valid;
	localparam [31:0] tpu_pkg_AW = 8;
	input wire signed [(N * tpu_pkg_AW) - 1:0] op_a;
	input wire signed [(N * tpu_pkg_AW) - 1:0] op_b;
	output wire res_valid;
	localparam [31:0] tpu_pkg_ACCW = 32;
	output wire signed [31:0] res_data;
	output wire res_last;
	output wire [1:0] status;
	localparam [3:0] OPC_GEMM_C = 4'd3;
	localparam [2:0] DT_INT8_C = 3'd0;
	wire [3:0] wd_opclass = eng_wd[127:124];
	wire [2:0] wd_dtype = eng_wd[123:121];
	localparam [31:0] tpu_pkg_KW = 16;
	wire [15:0] wd_m = eng_wd[116:101];
	wire [15:0] wd_n = eng_wd[100:85];
	wire [15:0] wd_k = eng_wd[84:69];
	reg [TAGW - 1:0] tag_q;
	wire ctrl_busy;
	wire ctrl_done;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			tag_q <= 1'sb0;
		else if (eng_valid && eng_ready)
			tag_q <= eng_tag;
	wire arr_clr;
	wire arr_en;
	wire arr_shift;
	wire feed_flush;
	wire feed_valid;
	wire row_valid;
	wire row_last;
	wire drain_busy;
	wire signed [(N * tpu_pkg_AW) - 1:0] a_skew;
	wire signed [(N * tpu_pkg_AW) - 1:0] b_skew;
	wire signed [(N * tpu_pkg_ACCW) - 1:0] acc_south;
	tpu_ctrl #(.N(N)) u_ctrl(
		.clk(clk),
		.rst_n(rst_n),
		.start(eng_valid && eng_ready),
		.dim_m(wd_m),
		.dim_n(wd_n),
		.dim_k(wd_k),
		.opclass_ok(wd_opclass == OPC_GEMM_C),
		.dtype_ok(wd_dtype == DT_INT8_C),
		.op_ready(op_ready),
		.op_valid(op_valid),
		.arr_clr(arr_clr),
		.arr_en(arr_en),
		.feed_valid(feed_valid),
		.arr_shift(arr_shift),
		.feed_flush(feed_flush),
		.row_valid(row_valid),
		.row_last(row_last),
		.drain_busy(drain_busy),
		.done(ctrl_done),
		.status(status),
		.busy(ctrl_busy)
	);
	reg signed [(N * tpu_pkg_AW) - 1:0] a_rev;
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < N; i = i + 1)
				a_rev[((N - 1) - i) * tpu_pkg_AW+:tpu_pkg_AW] = op_a[((N - 1) - ((N - 1) - i)) * tpu_pkg_AW+:tpu_pkg_AW];
		end
	end
	tpu_feeder #(.N(N)) u_feed(
		.clk(clk),
		.rst_n(rst_n),
		.flush(feed_flush),
		.step(arr_en),
		.in_valid(feed_valid),
		.a_slice(a_rev),
		.b_slice(op_b),
		.a_skew(a_skew),
		.b_skew(b_skew)
	);
	tpu_array #(.N(N)) u_array(
		.clk(clk),
		.rst_n(rst_n),
		.en(arr_en),
		.clr(arr_clr),
		.shift_en(arr_shift),
		.a_west(a_skew),
		.b_north(b_skew),
		.acc_south(acc_south)
	);
	reg [(N * tpu_pkg_ACCW) - 1:0] south_packed;
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_2
			reg signed [31:0] i;
			for (i = 0; i < N; i = i + 1)
				south_packed[i * tpu_pkg_ACCW+:tpu_pkg_ACCW] = acc_south[((N - 1) - i) * tpu_pkg_ACCW+:tpu_pkg_ACCW];
		end
	end
	tpu_drain #(.N(N)) u_drain(
		.clk(clk),
		.rst_n(rst_n),
		.row_valid(row_valid),
		.row(south_packed),
		.row_last(row_last),
		.res_valid(res_valid),
		.res_data(res_data),
		.res_last(res_last),
		.busy(drain_busy)
	);
	assign eng_ready = !ctrl_busy;
	assign eng_done = ctrl_done;
	assign eng_done_tag = tag_q;
	wire _unused_wd = &{1'b0, eng_wd};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
`default_nettype wire
`default_nettype none
module simd_alu (
	op,
	a,
	b,
	y
);
	reg _sv2v_0;
	input wire [2:0] op;
	localparam [31:0] simd_pkg_EW = 32;
	input wire signed [31:0] a;
	input wire signed [31:0] b;
	output reg signed [31:0] y;
	wire signed [63:0] prod = a * b;
	wire _unused_hi = &{1'b0, prod[63:simd_pkg_EW]};
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (op)
			3'd0: y = a + b;
			3'd1: y = a - b;
			3'd2: y = prod[31:0];
			3'd3: y = (a > b ? a : b);
			3'd4: y = (a < b ? a : b);
			3'd5: y = a & b;
			3'd6: y = a | b;
			3'd7: y = a ^ b;
			default: y = 1'sb0;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module simd_ctrl (
	clk,
	rst_n,
	start,
	dim_k,
	opclass_ok,
	is_reduce,
	dtype_ok,
	op_ready,
	op_valid,
	lanes_valid,
	acc_clr,
	emit_group,
	emit_last,
	serial_busy,
	lanes_out_valid,
	done,
	status,
	busy
);
	reg _sv2v_0;
	localparam [31:0] simd_pkg_NLANE = 4;
	parameter [31:0] N = simd_pkg_NLANE;
	input wire clk;
	input wire rst_n;
	input wire start;
	localparam [31:0] simd_pkg_CNTW = 16;
	input wire [15:0] dim_k;
	input wire opclass_ok;
	input wire is_reduce;
	input wire dtype_ok;
	output reg op_ready;
	input wire op_valid;
	output reg lanes_valid;
	output reg acc_clr;
	output reg emit_group;
	output reg emit_last;
	input wire serial_busy;
	input wire lanes_out_valid;
	output reg done;
	output reg [1:0] status;
	output reg busy;
	reg [2:0] st_q;
	reg [15:0] k_left_q;
	reg reduce_q;
	reg [1:0] tail_q;
	reg [1:0] status_q;
	wire dims_ok = dim_k != 0;
	wire job_ok = (opclass_ok && dtype_ok) && dims_ok;
	wire [1:0] why = (!opclass_ok ? 2'd1 : (!dtype_ok ? 2'd2 : 2'd3));
	function automatic signed [15:0] sv2v_cast_9432F_signed;
		input reg signed [15:0] inp;
		sv2v_cast_9432F_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			st_q <= 3'd0;
			k_left_q <= 1'sb0;
			reduce_q <= 1'b0;
			tail_q <= 1'sb0;
			status_q <= 2'd0;
		end
		else
			(* full_case, parallel_case *)
			case (st_q)
				3'd0:
					if (start) begin
						reduce_q <= is_reduce;
						if (job_ok) begin
							st_q <= 3'd1;
							k_left_q <= dim_k;
							status_q <= 2'd0;
						end
						else begin
							st_q <= 3'd4;
							status_q <= why;
						end
					end
				3'd1:
					if (op_valid && op_ready) begin
						if (k_left_q == sv2v_cast_9432F_signed(1)) begin
							st_q <= 3'd2;
							tail_q <= 2'd0;
						end
						k_left_q <= k_left_q - sv2v_cast_9432F_signed(1);
					end
				3'd2:
					if (tail_q != 2'd2)
						tail_q <= tail_q + 2'd1;
					else if (!serial_busy && !lanes_out_valid)
						st_q <= (reduce_q ? 3'd3 : 3'd4);
				3'd3:
					if (!serial_busy)
						st_q <= 3'd4;
				3'd4: st_q <= 3'd0;
				default: st_q <= 3'd0;
			endcase
	always @(*) begin
		if (_sv2v_0)
			;
		op_ready = (st_q == 3'd1) && (reduce_q || (!serial_busy && !lanes_out_valid));
		lanes_valid = ((st_q == 3'd1) && op_valid) && op_ready;
		acc_clr = (st_q == 3'd0) && start;
		emit_group = !reduce_q && lanes_out_valid;
		emit_last = emit_group && (st_q == 3'd2);
		done = st_q == 3'd4;
		status = status_q;
		busy = st_q != 3'd0;
	end
	wire _unused_n = &{1'b0, N[0]};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module simd_lanes (
	clk,
	rst_n,
	in_valid,
	op,
	a,
	b,
	out_valid,
	y
);
	localparam [31:0] simd_pkg_NLANE = 4;
	parameter [31:0] N = simd_pkg_NLANE;
	input wire clk;
	input wire rst_n;
	input wire in_valid;
	input wire [2:0] op;
	localparam [31:0] simd_pkg_EW = 32;
	input wire [(N * simd_pkg_EW) - 1:0] a;
	input wire [(N * simd_pkg_EW) - 1:0] b;
	output reg out_valid;
	output reg [(N * simd_pkg_EW) - 1:0] y;
	wire [(N * simd_pkg_EW) - 1:0] y_comb;
	genvar _gv_l_1;
	generate
		for (_gv_l_1 = 0; _gv_l_1 < N; _gv_l_1 = _gv_l_1 + 1) begin : g_lane
			localparam l = _gv_l_1;
			simd_alu u_alu(
				.op(op),
				.a(a[l * simd_pkg_EW+:simd_pkg_EW]),
				.b(b[l * simd_pkg_EW+:simd_pkg_EW]),
				.y(y_comb[l * simd_pkg_EW+:simd_pkg_EW])
			);
		end
	endgenerate
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			y <= 1'sb0;
			out_valid <= 1'b0;
		end
		else begin
			y <= y_comb;
			out_valid <= in_valid;
		end
endmodule
`default_nettype wire
`default_nettype none
module simd_reduce (
	clk,
	rst_n,
	clr,
	in_valid,
	y,
	acc
);
	reg _sv2v_0;
	localparam [31:0] simd_pkg_NLANE = 4;
	parameter [31:0] N = simd_pkg_NLANE;
	input wire clk;
	input wire rst_n;
	input wire clr;
	input wire in_valid;
	localparam [31:0] simd_pkg_EW = 32;
	input wire [(N * simd_pkg_EW) - 1:0] y;
	output reg signed [31:0] acc;
	reg signed [31:0] lane_sum;
	always @(*) begin
		if (_sv2v_0)
			;
		lane_sum = 1'sb0;
		begin : sv2v_autoblock_1
			reg signed [31:0] l;
			for (l = 0; l < N; l = l + 1)
				lane_sum = lane_sum + $signed(y[l * simd_pkg_EW+:simd_pkg_EW]);
		end
	end
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			acc <= 1'sb0;
		else if (clr)
			acc <= 1'sb0;
		else if (in_valid)
			acc <= acc + lane_sum;
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module simd_serial (
	clk,
	rst_n,
	in_valid,
	y,
	in_last,
	res_valid,
	res_data,
	res_last,
	busy
);
	localparam [31:0] simd_pkg_NLANE = 4;
	parameter [31:0] N = simd_pkg_NLANE;
	input wire clk;
	input wire rst_n;
	input wire in_valid;
	localparam [31:0] simd_pkg_EW = 32;
	input wire [(N * simd_pkg_EW) - 1:0] y;
	input wire in_last;
	output wire res_valid;
	output wire signed [31:0] res_data;
	output wire res_last;
	output wire busy;
	reg [(N * simd_pkg_EW) - 1:0] buf_q;
	reg [$clog2(N + 1) - 1:0] idx_q;
	reg last_q;
	reg active_q;
	function automatic [$clog2(N + 1) - 1:0] sv2v_cast_54CAC;
		input reg [$clog2(N + 1) - 1:0] inp;
		sv2v_cast_54CAC = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			buf_q <= 1'sb0;
			idx_q <= 1'sb0;
			last_q <= 1'b0;
			active_q <= 1'b0;
		end
		else if (in_valid && !active_q) begin
			buf_q <= y;
			idx_q <= 1'sb0;
			last_q <= in_last;
			active_q <= 1'b1;
		end
		else if (active_q) begin
			if (idx_q == sv2v_cast_54CAC(N - 1))
				active_q <= 1'b0;
			else
				idx_q <= idx_q + 1'b1;
		end
	assign res_valid = active_q;
	assign res_data = $signed(buf_q[idx_q * simd_pkg_EW+:simd_pkg_EW]);
	assign res_last = (active_q && last_q) && (idx_q == sv2v_cast_54CAC(N - 1));
	assign busy = active_q;
endmodule
`default_nettype wire
`default_nettype none
module simd_top (
	clk,
	rst_n,
	eng_valid,
	eng_ready,
	eng_wd,
	eng_tag,
	eng_done,
	eng_done_tag,
	op_ready,
	op_valid,
	op_a,
	op_b,
	res_valid,
	res_data,
	res_last,
	status
);
	localparam [31:0] simd_pkg_NLANE = 4;
	parameter [31:0] N = simd_pkg_NLANE;
	parameter [31:0] WD_W = 128;
	parameter [31:0] TAGW = 4;
	input wire clk;
	input wire rst_n;
	input wire eng_valid;
	output wire eng_ready;
	input wire [WD_W - 1:0] eng_wd;
	input wire [TAGW - 1:0] eng_tag;
	output wire eng_done;
	output wire [TAGW - 1:0] eng_done_tag;
	output wire op_ready;
	input wire op_valid;
	localparam [31:0] simd_pkg_EW = 32;
	input wire [(N * simd_pkg_EW) - 1:0] op_a;
	input wire [(N * simd_pkg_EW) - 1:0] op_b;
	output wire res_valid;
	output wire signed [31:0] res_data;
	output wire res_last;
	output wire [1:0] status;
	localparam [3:0] OPC_SCALAR_C = 4'd0;
	localparam [3:0] OPC_ELEMENT_C = 4'd1;
	localparam [3:0] OPC_REDUCE_C = 4'd2;
	localparam [2:0] DT_INT32_C = 3'd2;
	wire [3:0] wd_opclass = eng_wd[127:124];
	wire [2:0] wd_dtype = eng_wd[123:121];
	localparam [31:0] simd_pkg_CNTW = 16;
	wire [15:0] wd_m = eng_wd[116:101];
	wire m_aligned = (wd_m[$clog2(N) - 1:0] == {$clog2(N) * 1 {1'sb0}}) && (wd_m != {16 {1'sb0}});
	wire [15:0] wd_groups = (m_aligned ? wd_m >> $clog2(N) : {16 {1'sb0}});
	wire [2:0] wd_op = eng_wd[2:0];
	wire accept = eng_valid && eng_ready;
	reg [TAGW - 1:0] tag_q;
	reg [2:0] op_q;
	reg reduce_q;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			tag_q <= 1'sb0;
			op_q <= 3'd0;
			reduce_q <= 1'b0;
		end
		else if (accept) begin
			tag_q <= eng_tag;
			op_q <= wd_op;
			reduce_q <= wd_opclass == OPC_REDUCE_C;
		end
	wire lanes_valid;
	wire acc_clr;
	wire emit_group;
	wire emit_last;
	wire serial_busy;
	wire lanes_out_valid;
	wire ctrl_busy;
	wire ctrl_done;
	wire [(N * simd_pkg_EW) - 1:0] lanes_y;
	wire signed [31:0] acc;
	simd_ctrl #(.N(N)) u_ctrl(
		.clk(clk),
		.rst_n(rst_n),
		.start(accept),
		.dim_k(wd_groups),
		.opclass_ok(((wd_opclass == OPC_ELEMENT_C) || (wd_opclass == OPC_REDUCE_C)) || (wd_opclass == OPC_SCALAR_C)),
		.is_reduce(wd_opclass == OPC_REDUCE_C),
		.dtype_ok(wd_dtype == DT_INT32_C),
		.op_ready(op_ready),
		.op_valid(op_valid),
		.lanes_valid(lanes_valid),
		.acc_clr(acc_clr),
		.emit_group(emit_group),
		.emit_last(emit_last),
		.serial_busy(serial_busy),
		.lanes_out_valid(lanes_out_valid),
		.done(ctrl_done),
		.status(status),
		.busy(ctrl_busy)
	);
	simd_lanes #(.N(N)) u_lanes(
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(lanes_valid),
		.op(op_q),
		.a(op_a),
		.b(op_b),
		.out_valid(lanes_out_valid),
		.y(lanes_y)
	);
	simd_reduce #(.N(N)) u_reduce(
		.clk(clk),
		.rst_n(rst_n),
		.clr(acc_clr),
		.in_valid(lanes_out_valid && reduce_q),
		.y(lanes_y),
		.acc(acc)
	);
	wire ser_valid;
	wire signed [31:0] ser_data;
	wire ser_last;
	simd_serial #(.N(N)) u_ser(
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(emit_group),
		.y(lanes_y),
		.in_last(emit_last),
		.res_valid(ser_valid),
		.res_data(ser_data),
		.res_last(ser_last),
		.busy(serial_busy)
	);
	wire reduce_emit = reduce_q && ctrl_done;
	assign res_valid = (reduce_emit ? 1'b1 : ser_valid);
	assign res_data = (reduce_emit ? acc : ser_data);
	assign res_last = (reduce_emit ? 1'b1 : ser_last);
	assign eng_ready = !ctrl_busy;
	assign eng_done = ctrl_done;
	assign eng_done_tag = tag_q;
	wire _unused_wd = &{1'b0, eng_wd};
endmodule
`default_nettype wire
`default_nettype none
module hydra_dma_agen (
	clk,
	rst_n,
	load,
	base_a,
	base_b,
	base_c,
	step_rd,
	peek,
	step_wr,
	addr_a,
	addr_b,
	addr_c,
	rd_count,
	wr_count
);
	parameter [31:0] AW = 9;
	parameter [31:0] CAW = AW;
	parameter [31:0] CNTW = 16;
	input wire clk;
	input wire rst_n;
	input wire load;
	input wire [AW - 1:0] base_a;
	input wire [AW - 1:0] base_b;
	input wire [CAW - 1:0] base_c;
	input wire step_rd;
	input wire peek;
	input wire step_wr;
	output wire [AW - 1:0] addr_a;
	output wire [AW - 1:0] addr_b;
	output wire [CAW - 1:0] addr_c;
	output wire [CNTW - 1:0] rd_count;
	output wire [CNTW - 1:0] wr_count;
	reg [AW - 1:0] ba_q;
	reg [AW - 1:0] bb_q;
	reg [CAW - 1:0] bc_q;
	reg [CNTW - 1:0] rd_q;
	reg [CNTW - 1:0] wr_q;
	function automatic signed [CNTW - 1:0] sv2v_cast_1954F_signed;
		input reg signed [CNTW - 1:0] inp;
		sv2v_cast_1954F_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			ba_q <= 1'sb0;
			bb_q <= 1'sb0;
			bc_q <= 1'sb0;
			rd_q <= 1'sb0;
			wr_q <= 1'sb0;
		end
		else if (load) begin
			ba_q <= base_a;
			bb_q <= base_b;
			bc_q <= base_c;
			rd_q <= 1'sb0;
			wr_q <= 1'sb0;
		end
		else begin
			if (step_rd)
				rd_q <= rd_q + sv2v_cast_1954F_signed(1);
			if (step_wr)
				wr_q <= wr_q + sv2v_cast_1954F_signed(1);
		end
	function automatic [AW - 1:0] sv2v_cast_DE851;
		input reg [AW - 1:0] inp;
		sv2v_cast_DE851 = inp;
	endfunction
	assign addr_a = (ba_q + sv2v_cast_DE851(rd_q)) + sv2v_cast_DE851(peek);
	assign addr_b = (bb_q + sv2v_cast_DE851(rd_q)) + sv2v_cast_DE851(peek);
	function automatic [CAW - 1:0] sv2v_cast_5C013;
		input reg [CAW - 1:0] inp;
		sv2v_cast_5C013 = inp;
	endfunction
	assign addr_c = bc_q + sv2v_cast_5C013(wr_q);
	assign rd_count = rd_q;
	assign wr_count = wr_q;
endmodule
`default_nettype wire
`default_nettype none
module hydra_dma_gemm (
	clk,
	rst_n,
	start,
	base_a,
	base_b,
	base_c,
	k_slices,
	n_results,
	busy,
	a_addr,
	a_rdata,
	b_addr,
	b_rdata,
	w_addr,
	w_rdata,
	c_addr,
	c_we,
	c_wdata,
	op_valid,
	op_ready,
	op_a,
	op_b,
	op_w,
	res_valid,
	res_data
);
	parameter [31:0] AW = 10;
	parameter [31:0] DW = 32;
	parameter [31:0] CAW = AW;
	parameter [31:0] CNTW = 16;
	input wire clk;
	input wire rst_n;
	input wire start;
	input wire [AW - 1:0] base_a;
	input wire [AW - 1:0] base_b;
	input wire [CAW - 1:0] base_c;
	input wire [CNTW - 1:0] k_slices;
	input wire [CNTW - 1:0] n_results;
	output wire busy;
	output wire [AW - 1:0] a_addr;
	input wire [DW - 1:0] a_rdata;
	output wire [AW - 1:0] b_addr;
	input wire [DW - 1:0] b_rdata;
	output wire [AW - 1:0] w_addr;
	input wire [DW - 1:0] w_rdata;
	output wire [CAW - 1:0] c_addr;
	output wire c_we;
	output wire [31:0] c_wdata;
	output wire op_valid;
	input wire op_ready;
	output wire [DW - 1:0] op_a;
	output wire [DW - 1:0] op_b;
	output wire [DW - 1:0] op_w;
	input wire res_valid;
	input wire [31:0] res_data;
	reg [1:0] st_q;
	reg [CNTW - 1:0] k_q;
	reg [CNTW - 1:0] n_q;
	reg [CNTW - 1:0] k_left_q;
	reg [DW - 1:0] hold_a_q;
	reg [DW - 1:0] hold_b_q;
	reg [DW - 1:0] hold_w_q;
	reg hold_valid_q;
	wire [CNTW - 1:0] cur;
	wire go = start && (st_q == 2'd0);
	wire xfer = op_valid && op_ready;
	wire bank_ok = (st_q == 2'd2) && (cur < k_q);
	wire capture = bank_ok && (!hold_valid_q || xfer);
	wire [CNTW - 1:0] wr_cnt;
	hydra_dma_agen #(
		.AW(AW),
		.CAW(CAW),
		.CNTW(CNTW)
	) u_agen(
		.clk(clk),
		.rst_n(rst_n),
		.load(go),
		.base_a(base_a),
		.base_b(base_b),
		.base_c(base_c),
		.step_rd(capture),
		.peek(capture),
		.step_wr(res_valid),
		.addr_a(a_addr),
		.addr_b(b_addr),
		.addr_c(c_addr),
		.rd_count(cur),
		.wr_count(wr_cnt)
	);
	wire _unused_wr = &{1'b0, wr_cnt};
	assign w_addr = a_addr;
	reg [CNTW - 1:0] res_seen_q;
	wire busy_hold = res_seen_q < n_q;
	function automatic signed [CNTW - 1:0] sv2v_cast_1954F_signed;
		input reg signed [CNTW - 1:0] inp;
		sv2v_cast_1954F_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			st_q <= 2'd0;
			k_q <= 1'sb0;
			k_left_q <= 1'sb0;
			n_q <= 1'sb0;
			hold_valid_q <= 1'b0;
			hold_a_q <= 1'sb0;
			hold_b_q <= 1'sb0;
			hold_w_q <= 1'sb0;
		end
		else begin
			if (capture) begin
				hold_a_q <= a_rdata;
				hold_b_q <= b_rdata;
				hold_w_q <= w_rdata;
				hold_valid_q <= 1'b1;
			end
			else if (xfer)
				hold_valid_q <= 1'b0;
			(* full_case, parallel_case *)
			case (st_q)
				2'd0:
					if (go) begin
						k_q <= k_slices;
						n_q <= n_results;
						k_left_q <= k_slices;
						hold_valid_q <= 1'b0;
						st_q <= (k_slices == {CNTW {1'sb0}} ? 2'd0 : 2'd1);
					end
				2'd1: st_q <= 2'd2;
				2'd2:
					if (xfer) begin
						if (k_left_q == sv2v_cast_1954F_signed(1))
							st_q <= 2'd3;
						k_left_q <= k_left_q - sv2v_cast_1954F_signed(1);
					end
				2'd3:
					if (!res_valid && !busy_hold)
						st_q <= 2'd0;
				default: st_q <= 2'd0;
			endcase
		end
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			res_seen_q <= 1'sb0;
		else if (go)
			res_seen_q <= 1'sb0;
		else if (res_valid)
			res_seen_q <= res_seen_q + sv2v_cast_1954F_signed(1);
	assign op_valid = (st_q == 2'd2) && hold_valid_q;
	assign op_a = hold_a_q;
	assign op_b = hold_b_q;
	assign op_w = hold_w_q;
	assign c_we = res_valid;
	assign c_wdata = res_data;
	assign busy = st_q != 2'd0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_spram (
	clk,
	we,
	addr,
	wdata,
	rdata
);
	parameter [31:0] DW = 32;
	parameter [31:0] DEPTH = 512;
	parameter [31:0] AW = $clog2(DEPTH);
	input wire clk;
	input wire we;
	input wire [AW - 1:0] addr;
	input wire [DW - 1:0] wdata;
	output reg [DW - 1:0] rdata;
	reg [DW - 1:0] mem [0:DEPTH - 1];
	always @(posedge clk) begin
		if (we)
			mem[addr] <= wdata;
		rdata <= mem[addr];
	end
endmodule
`default_nettype wire
`default_nettype none
module hydra_sha256 (
	clk,
	rst_n,
	init,
	w_we,
	w_addr,
	w_data,
	go,
	busy,
	done,
	digest
);
	input wire clk;
	input wire rst_n;
	input wire init;
	input wire w_we;
	input wire [3:0] w_addr;
	input wire [31:0] w_data;
	input wire go;
	output reg busy;
	output reg done;
	output wire [255:0] digest;
	localparam [2047:0] K = 2048'h428a2f9871374491b5c0fbcfe9b5dba53956c25b59f111f1923f82a4ab1c5ed5d807aa9812835b01243185be550c7dc372be5d7480deb1fe9bdc06a7c19bf174e49b69c1efbe47860fc19dc6240ca1cc2de92c6f4a7484aa5cb0a9dc76f988da983e5152a831c66db00327c8bf597fc7c6e00bf3d5a7914706ca63511429296727b70a852e1b21384d2c6dfc53380d13650a7354766a0abb81c2c92e92722c85a2bfe8a1a81a664bc24b8b70c76c51a3d192e819d6990624f40e3585106aa07019a4c1161e376c082748774c34b0bcb5391c0cb34ed8aa4a5b9cca4f682e6ff3748f82ee78a5636f84c878148cc7020890befffaa4506cebbef9a3f7c67178f2;
	localparam [255:0] IV = 256'h6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19;
	function automatic [31:0] rotr;
		input reg [31:0] x;
		input reg signed [31:0] n;
		rotr = (x >> n) | (x << (32 - n));
	endfunction
	reg [31:0] w [0:15];
	wire [31:0] w_cur = w[0];
	reg [31:0] h [0:7];
	reg [31:0] a;
	reg [31:0] b;
	reg [31:0] c;
	reg [31:0] d;
	reg [31:0] e;
	reg [31:0] f;
	reg [31:0] g;
	reg [31:0] hh;
	reg [6:0] round;
	wire [31:0] sig0 = (rotr(w[1], 7) ^ rotr(w[1], 18)) ^ (w[1] >> 3);
	wire [31:0] sig1 = (rotr(w[14], 17) ^ rotr(w[14], 19)) ^ (w[14] >> 10);
	wire [31:0] w_nx = ((w[0] + sig0) + w[9]) + sig1;
	wire [31:0] sum1 = (rotr(e, 6) ^ rotr(e, 11)) ^ rotr(e, 25);
	wire [31:0] ch = (e & f) ^ (~e & g);
	wire [31:0] t1 = (((hh + sum1) + ch) + K[(63 - round[5:0]) * 32+:32]) + w_cur;
	wire [31:0] sum0 = (rotr(a, 2) ^ rotr(a, 13)) ^ rotr(a, 22);
	wire [31:0] maj = ((a & b) ^ (a & c)) ^ (b & c);
	wire [31:0] t2 = sum0 + maj;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			begin : sv2v_autoblock_1
				reg signed [31:0] i;
				for (i = 0; i < 8; i = i + 1)
					h[i] <= IV[(7 - i) * 32+:32];
			end
			begin : sv2v_autoblock_2
				reg signed [31:0] i;
				for (i = 0; i < 16; i = i + 1)
					w[i] <= 1'sb0;
			end
			busy <= 1'b0;
			done <= 1'b0;
			round <= 1'sb0;
			a <= 1'sb0;
			b <= 1'sb0;
			c <= 1'sb0;
			d <= 1'sb0;
			e <= 1'sb0;
			f <= 1'sb0;
			g <= 1'sb0;
			hh <= 1'sb0;
		end
		else begin
			done <= 1'b0;
			if (init && !busy) begin : sv2v_autoblock_3
				reg signed [31:0] i;
				for (i = 0; i < 8; i = i + 1)
					h[i] <= IV[(7 - i) * 32+:32];
			end
			if (w_we && !busy)
				w[w_addr] <= w_data;
			if (go && !busy) begin
				busy <= 1'b1;
				round <= 1'sb0;
				a <= h[0];
				b <= h[1];
				c <= h[2];
				d <= h[3];
				e <= h[4];
				f <= h[5];
				g <= h[6];
				hh <= h[7];
			end
			else if (busy) begin
				if (round == 7'd64) begin
					h[0] <= h[0] + a;
					h[1] <= h[1] + b;
					h[2] <= h[2] + c;
					h[3] <= h[3] + d;
					h[4] <= h[4] + e;
					h[5] <= h[5] + f;
					h[6] <= h[6] + g;
					h[7] <= h[7] + hh;
					busy <= 1'b0;
					done <= 1'b1;
				end
				else begin
					hh <= g;
					g <= f;
					f <= e;
					e <= d + t1;
					d <= c;
					c <= b;
					b <= a;
					a <= t1 + t2;
					begin : sv2v_autoblock_4
						reg signed [31:0] i;
						for (i = 0; i < 15; i = i + 1)
							w[i] <= w[i + 1];
					end
					w[15] <= w_nx;
					round <= round + 7'd1;
				end
			end
		end
	assign digest = {h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]};
endmodule
`default_nettype wire
`default_nettype none
module hydra_sha256_stream (
	clk,
	rst_n,
	start,
	in_valid,
	in_ready,
	in_data,
	in_bytes,
	in_last,
	busy,
	done,
	digest,
	err,
	msg_bits
);
	reg _sv2v_0;
	parameter [0:0] F_BLOCKS = 1'b0;
	input wire clk;
	input wire rst_n;
	input wire start;
	input wire in_valid;
	output wire in_ready;
	input wire [31:0] in_data;
	input wire [2:0] in_bytes;
	input wire in_last;
	output wire busy;
	output reg done;
	output wire [255:0] digest;
	output reg err;
	output wire [63:0] msg_bits;
	reg sha_init;
	reg sha_w_we;
	reg sha_go;
	reg [3:0] sha_w_addr;
	reg [31:0] sha_w_data;
	wire sha_busy;
	wire sha_done;
	wire [255:0] sha_digest;
	hydra_sha256 u_core(
		.clk(clk),
		.rst_n(rst_n),
		.init(sha_init),
		.w_we(sha_w_we),
		.w_addr(sha_w_addr),
		.w_data(sha_w_data),
		.go(sha_go),
		.busy(sha_busy),
		.done(sha_done),
		.digest(sha_digest)
	);
	reg [2:0] st;
	reg [4:0] widx;
	reg [60:0] nbytes;
	reg pad80;
	reg len_hi;
	reg tail;
	reg final_blk;
	reg have;
	assign msg_bits = {nbytes, 3'b000};
	wire hs = in_valid && in_ready;
	wire bad = (in_bytes > 3'd4) || (!in_last && (in_bytes != 3'd4));
	function automatic [31:0] tail_word;
		input reg [31:0] d;
		input reg [2:0] b;
		reg [31:0] keep;
		begin
			keep = (b == 3'd0 ? 32'h00000000 : 32'hffffffff << (8 * (4 - b)));
			tail_word = (d & keep) | (32'h80000000 >> (8 * b));
		end
	endfunction
	assign in_ready = (st == 3'd1) && !sha_busy;
	assign busy = ((st == 3'd2) || (st == 3'd3)) || (st == 3'd4);
	assign digest = (have ? sha_digest : {256 {1'sb0}});
	always @(*) begin
		if (_sv2v_0)
			;
		sha_init = 1'b0;
		sha_go = st == 3'd2;
		sha_w_we = 1'b0;
		sha_w_addr = widx[3:0];
		sha_w_data = 1'sb0;
		if (start && ((st == 3'd0) || (st == 3'd1)))
			sha_init = 1'b1;
		if ((((st == 3'd1) && hs) && !bad) && !start) begin
			if (!in_last || (in_bytes == 3'd4)) begin
				sha_w_we = 1'b1;
				sha_w_data = in_data;
			end
			else if (in_bytes != 3'd0) begin
				sha_w_we = 1'b1;
				sha_w_data = tail_word(in_data, in_bytes);
			end
		end
		if ((st == 3'd4) && (widx != 5'd16)) begin
			sha_w_we = 1'b1;
			if (!pad80)
				sha_w_data = 32'h80000000;
			else if (widx == 5'd14)
				sha_w_data = msg_bits[63:32];
			else if ((widx == 5'd15) && len_hi)
				sha_w_data = msg_bits[31:0];
			else
				sha_w_data = 32'h00000000;
		end
	end
	function automatic [60:0] sv2v_cast_61;
		input reg [60:0] inp;
		sv2v_cast_61 = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			st <= 3'd0;
			widx <= 1'sb0;
			nbytes <= 1'sb0;
			pad80 <= 1'b0;
			len_hi <= 1'b0;
			tail <= 1'b0;
			final_blk <= 1'b0;
			have <= 1'b0;
			done <= 1'b0;
			err <= 1'b0;
		end
		else begin
			done <= 1'b0;
			if (start && ((st == 3'd0) || (st == 3'd1))) begin
				st <= 3'd1;
				widx <= 1'sb0;
				nbytes <= 1'sb0;
				pad80 <= 1'b0;
				len_hi <= 1'b0;
				tail <= 1'b0;
				final_blk <= 1'b0;
				have <= 1'b0;
				err <= 1'b0;
			end
			else
				(* full_case, parallel_case *)
				case (st)
					3'd0:
						;
					3'd1:
						if (hs) begin
							if (bad) begin
								err <= 1'b1;
								st <= 3'd0;
							end
							else begin
								nbytes <= nbytes + sv2v_cast_61(in_bytes);
								if (!in_last) begin
									widx <= widx + 5'd1;
									if (widx == 5'd15)
										st <= 3'd2;
								end
								else begin
									tail <= 1'b1;
									st <= 3'd4;
									if (in_bytes != 3'd0)
										widx <= widx + 5'd1;
									pad80 <= (in_bytes != 3'd0) && (in_bytes != 3'd4);
								end
							end
						end
					3'd4:
						if (widx == 5'd16)
							st <= 3'd2;
						else begin
							widx <= widx + 5'd1;
							if (!pad80)
								pad80 <= 1'b1;
							else if (widx == 5'd14)
								len_hi <= 1'b1;
							else if ((widx == 5'd15) && len_hi) begin
								final_blk <= 1'b1;
								st <= 3'd2;
							end
						end
					3'd2: st <= 3'd3;
					3'd3:
						if (sha_done) begin
							widx <= 1'sb0;
							if (final_blk) begin
								st <= 3'd0;
								have <= 1'b1;
								done <= 1'b1;
							end
							else
								st <= (tail ? 3'd4 : 3'd1);
						end
					default: st <= 3'd0;
				endcase
		end
	wire _unused_fblocks = &{1'b0, F_BLOCKS};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_measure (
	clk,
	rst_n,
	start,
	start_ready,
	in_valid,
	in_ready,
	in_data,
	in_bytes,
	in_last,
	busy,
	done,
	err,
	image_digest,
	pcr,
	extend_count
);
	reg _sv2v_0;
	input wire clk;
	input wire rst_n;
	input wire start;
	output wire start_ready;
	input wire in_valid;
	output wire in_ready;
	input wire [31:0] in_data;
	input wire [2:0] in_bytes;
	input wire in_last;
	output wire busy;
	output reg done;
	output reg err;
	output wire [255:0] image_digest;
	output reg [255:0] pcr;
	output reg [15:0] extend_count;
	reg [2:0] ph;
	reg s_start;
	reg s_valid;
	wire s_ready;
	reg s_last;
	wire s_busy;
	wire s_done;
	wire s_err;
	reg [31:0] s_data;
	reg [2:0] s_bytes;
	wire [255:0] s_digest;
	wire [63:0] s_bits;
	hydra_sha256_stream u_sha(
		.clk(clk),
		.rst_n(rst_n),
		.start(s_start),
		.in_valid(s_valid),
		.in_ready(s_ready),
		.in_data(s_data),
		.in_bytes(s_bytes),
		.in_last(s_last),
		.busy(s_busy),
		.done(s_done),
		.digest(s_digest),
		.err(s_err),
		.msg_bits(s_bits)
	);
	wire _unused_bits = &{1'b0, s_bits};
	reg [3:0] widx;
	reg [255:0] img_q;
	wire [511:0] ext_msg = {pcr, img_q};
	wire [31:0] ext_word = ext_msg[511 - (32 * widx)-:32];
	assign start_ready = (ph == 3'd0) && !s_busy;
	assign in_ready = (ph == 3'd1) && s_ready;
	always @(*) begin
		if (_sv2v_0)
			;
		s_start = 1'b0;
		s_valid = 1'b0;
		s_data = 1'sb0;
		s_bytes = 3'd4;
		s_last = 1'b0;
		(* full_case, parallel_case *)
		case (ph)
			3'd0: s_start = start;
			3'd1: begin
				s_valid = in_valid;
				s_data = in_data;
				s_bytes = in_bytes;
				s_last = in_last;
			end
			3'd2: s_start = 1'b1;
			3'd3: begin
				s_valid = 1'b1;
				s_data = ext_word;
				s_bytes = 3'd4;
				s_last = widx == 4'd15;
			end
			default:
				;
		endcase
	end
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			ph <= 3'd0;
			widx <= 1'sb0;
			img_q <= 1'sb0;
			pcr <= 1'sb0;
			extend_count <= 1'sb0;
			done <= 1'b0;
			err <= 1'b0;
		end
		else begin
			done <= 1'b0;
			(* full_case, parallel_case *)
			case (ph)
				3'd0:
					if (start && start_ready) begin
						ph <= 3'd1;
						err <= 1'b0;
					end
				3'd1:
					if (s_err) begin
						ph <= 3'd0;
						err <= 1'b1;
					end
					else if (s_done) begin
						img_q <= s_digest;
						ph <= 3'd2;
					end
				3'd2: begin
					widx <= 1'sb0;
					ph <= 3'd3;
				end
				3'd3:
					if (s_ready) begin
						widx <= widx + 4'd1;
						if (widx == 4'd15)
							ph <= 3'd4;
					end
				3'd4:
					if (s_done) begin
						pcr <= s_digest;
						extend_count <= extend_count + 16'd1;
						done <= 1'b1;
						ph <= 3'd0;
					end
				default: ph <= 3'd0;
			endcase
		end
	assign busy = ph != 3'd0;
	assign image_digest = img_q;
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_secure_boot (
	clk,
	rst_n,
	boot_start,
	boot_len,
	rd_addr,
	rd_data,
	busy,
	verified,
	failed,
	lock_load,
	lock_debug,
	digest,
	pcr,
	boots
);
	reg _sv2v_0;
	parameter [255:0] GOLDEN = 256'd0;
	parameter signed [31:0] AW = 14;
	input wire clk;
	input wire rst_n;
	input wire boot_start;
	input wire [AW:0] boot_len;
	output wire [AW - 1:0] rd_addr;
	input wire [31:0] rd_data;
	output wire busy;
	output reg verified;
	output reg failed;
	output wire lock_load;
	output wire lock_debug;
	output wire [255:0] digest;
	output wire [255:0] pcr;
	output reg [15:0] boots;
	reg [2:0] st;
	reg [AW:0] len_q;
	reg [AW:0] idx;
	reg m_start;
	reg m_valid;
	reg m_last;
	wire m_start_ready;
	wire m_ready;
	wire m_busy;
	wire m_done;
	wire m_err;
	wire [15:0] m_ext;
	wire [31:0] be_word = {rd_data[7:0], rd_data[15:8], rd_data[23:16], rd_data[31:24]};
	hydra_measure u_meas(
		.clk(clk),
		.rst_n(rst_n),
		.start(m_start),
		.start_ready(m_start_ready),
		.in_valid(m_valid),
		.in_ready(m_ready),
		.in_data(be_word),
		.in_bytes(3'd4),
		.in_last(m_last),
		.busy(m_busy),
		.done(m_done),
		.err(m_err),
		.image_digest(digest),
		.pcr(pcr),
		.extend_count(m_ext)
	);
	function automatic signed [((AW + 0) >= 0 ? AW + 1 : 1 - (AW + 0)) - 1:0] sv2v_cast_2BB65_signed;
		input reg signed [((AW + 0) >= 0 ? AW + 1 : 1 - (AW + 0)) - 1:0] inp;
		sv2v_cast_2BB65_signed = inp;
	endfunction
	wire len_ok = (boot_len != {(AW >= 0 ? AW + 1 : 1 - AW) {1'sb0}}) && (boot_len <= sv2v_cast_2BB65_signed(1 << AW));
	always @(*) begin
		if (_sv2v_0)
			;
		m_start = (st == 3'd1) && m_start_ready;
		m_valid = st == 3'd3;
		m_last = (st == 3'd3) && (idx == (len_q - 1'b1));
	end
	assign rd_addr = idx[AW - 1:0];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			st <= 3'd0;
			len_q <= 1'sb0;
			idx <= 1'sb0;
			verified <= 1'b0;
			failed <= 1'b0;
			boots <= 16'd0;
		end
		else
			case (st)
				3'd0:
					if (boot_start && !verified) begin
						boots <= boots + 16'd1;
						if (len_ok) begin
							len_q <= boot_len;
							idx <= 1'sb0;
							failed <= 1'b0;
							st <= 3'd1;
						end
						else
							failed <= 1'b1;
					end
				3'd1:
					if (m_start_ready)
						st <= 3'd2;
				3'd2: st <= 3'd3;
				3'd3:
					if (m_ready) begin
						if (m_last)
							st <= 3'd4;
						else begin
							idx <= idx + 1'b1;
							st <= 3'd2;
						end
					end
				3'd4:
					if (m_done) begin
						if (digest == GOLDEN)
							verified <= 1'b1;
						else
							failed <= 1'b1;
						st <= 3'd0;
					end
					else if (m_err) begin
						failed <= 1'b1;
						st <= 3'd0;
					end
				default: st <= 3'd0;
			endcase
	assign busy = st != 3'd0;
	assign lock_load = verified || busy;
	assign lock_debug = verified;
	wire _unused = &{1'b0, m_busy, m_ext};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_engine_tpu (
	clk,
	rst_n,
	eng_valid,
	eng_ready,
	eng_wd,
	eng_tag,
	eng_done,
	eng_done_tag,
	checksum,
	tiles_done,
	last_status
);
	reg _sv2v_0;
	localparam [31:0] tpu_pkg_N_PE = 4;
	parameter [31:0] N = tpu_pkg_N_PE;
	parameter [31:0] WD_W = 128;
	parameter [31:0] TAGW = 4;
	input wire clk;
	input wire rst_n;
	input wire eng_valid;
	output wire eng_ready;
	input wire [WD_W - 1:0] eng_wd;
	input wire [TAGW - 1:0] eng_tag;
	output wire eng_done;
	output wire [TAGW - 1:0] eng_done_tag;
	output reg [31:0] checksum;
	output reg [15:0] tiles_done;
	output wire [1:0] last_status;
	localparam [31:0] tpu_pkg_KW = 16;
	reg [15:0] k_idx_q;
	reg [15:0] m_q;
	reg [15:0] n_q;
	localparam [31:0] tpu_pkg_AW = 8;
	reg signed [(N * tpu_pkg_AW) - 1:0] op_a;
	reg signed [(N * tpu_pkg_AW) - 1:0] op_b;
	wire op_ready;
	wire op_valid;
	function automatic signed [15:0] sv2v_cast_9432F_signed;
		input reg signed [15:0] inp;
		sv2v_cast_9432F_signed = inp;
	endfunction
	function automatic [3:0] sv2v_cast_4;
		input reg [3:0] inp;
		sv2v_cast_4 = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < N; i = i + 1)
				begin
					op_a[((N - 1) - i) * tpu_pkg_AW+:tpu_pkg_AW] = (sv2v_cast_9432F_signed(i) < m_q ? $signed({4'b0000, sv2v_cast_4((3 * i) + (5 * k_idx_q))}) - 8'sd8 : {8 {1'sb0}});
					op_b[((N - 1) - i) * tpu_pkg_AW+:tpu_pkg_AW] = (sv2v_cast_9432F_signed(i) < n_q ? $signed({4'b0000, sv2v_cast_4((7 * i) + (11 * k_idx_q))}) - 8'sd8 : {8 {1'sb0}});
				end
		end
	end
	assign op_valid = 1'b1;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			k_idx_q <= 1'sb0;
			m_q <= 1'sb0;
			n_q <= 1'sb0;
		end
		else if (eng_valid && eng_ready) begin
			k_idx_q <= 1'sb0;
			m_q <= eng_wd[116:101];
			n_q <= eng_wd[100:85];
		end
		else if (op_valid && op_ready)
			k_idx_q <= k_idx_q + sv2v_cast_9432F_signed(1);
	wire res_valid;
	wire res_last;
	localparam [31:0] tpu_pkg_ACCW = 32;
	wire signed [31:0] res_data;
	tpu_top #(
		.N(N),
		.WD_W(WD_W),
		.TAGW(TAGW)
	) u_tpu(
		.clk(clk),
		.rst_n(rst_n),
		.eng_valid(eng_valid),
		.eng_ready(eng_ready),
		.eng_wd(eng_wd),
		.eng_tag(eng_tag),
		.eng_done(eng_done),
		.eng_done_tag(eng_done_tag),
		.op_ready(op_ready),
		.op_valid(op_valid),
		.op_a(op_a),
		.op_b(op_b),
		.res_valid(res_valid),
		.res_data(res_data),
		.res_last(res_last),
		.status(last_status)
	);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			checksum <= 1'sb0;
			tiles_done <= 1'sb0;
		end
		else begin
			if (res_valid)
				checksum <= {checksum[30:0], checksum[31]} ^ res_data;
			if (eng_done)
				tiles_done <= tiles_done + 16'd1;
		end
	wire _unused = &{res_last, 1'b0};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_engine_simd (
	clk,
	rst_n,
	eng_valid,
	eng_ready,
	eng_wd,
	eng_tag,
	eng_done,
	eng_done_tag,
	checksum,
	jobs_done,
	last_status
);
	reg _sv2v_0;
	localparam [31:0] simd_pkg_NLANE = 4;
	parameter [31:0] N = simd_pkg_NLANE;
	parameter [31:0] WD_W = 128;
	parameter [31:0] TAGW = 4;
	input wire clk;
	input wire rst_n;
	input wire eng_valid;
	output wire eng_ready;
	input wire [WD_W - 1:0] eng_wd;
	input wire [TAGW - 1:0] eng_tag;
	output wire eng_done;
	output wire [TAGW - 1:0] eng_done_tag;
	output reg [31:0] checksum;
	output reg [15:0] jobs_done;
	output wire [1:0] last_status;
	localparam [31:0] simd_pkg_CNTW = 16;
	reg [15:0] grp_q;
	localparam [31:0] simd_pkg_EW = 32;
	reg [(N * simd_pkg_EW) - 1:0] op_a;
	reg [(N * simd_pkg_EW) - 1:0] op_b;
	wire op_ready;
	wire op_valid = 1'b1;
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] l;
			for (l = 0; l < N; l = l + 1)
				begin
					op_a[l * simd_pkg_EW+:simd_pkg_EW] = (32'h01010101 * sv2v_cast_32_signed(l + 1)) + sv2v_cast_32(grp_q);
					op_b[l * simd_pkg_EW+:simd_pkg_EW] = (32'h00010001 * sv2v_cast_32_signed(l + 2)) + (sv2v_cast_32(grp_q) << 3);
				end
		end
	end
	function automatic signed [15:0] sv2v_cast_9432F_signed;
		input reg signed [15:0] inp;
		sv2v_cast_9432F_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			grp_q <= 1'sb0;
		else if (eng_valid && eng_ready)
			grp_q <= 1'sb0;
		else if (op_valid && op_ready)
			grp_q <= grp_q + sv2v_cast_9432F_signed(1);
	wire res_valid;
	wire res_last;
	wire signed [31:0] res_data;
	simd_top #(
		.N(N),
		.WD_W(WD_W),
		.TAGW(TAGW)
	) u_simd(
		.clk(clk),
		.rst_n(rst_n),
		.eng_valid(eng_valid),
		.eng_ready(eng_ready),
		.eng_wd(eng_wd),
		.eng_tag(eng_tag),
		.eng_done(eng_done),
		.eng_done_tag(eng_done_tag),
		.op_ready(op_ready),
		.op_valid(op_valid),
		.op_a(op_a),
		.op_b(op_b),
		.res_valid(res_valid),
		.res_data(res_data),
		.res_last(res_last),
		.status(last_status)
	);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			checksum <= 1'sb0;
			jobs_done <= 1'sb0;
		end
		else begin
			if (res_valid)
				checksum <= {checksum[30:0], checksum[31]} ^ res_data;
			if (eng_done)
				jobs_done <= jobs_done + 16'd1;
		end
	wire _unused = &{res_last, 1'b0};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_engine_tpu_dma (
	clk,
	rst_n,
	eng_valid,
	eng_ready,
	eng_wd,
	eng_tag,
	eng_done,
	eng_done_tag,
	ld_we,
	ld_bank,
	ld_addr,
	ld_data,
	ld_refused,
	c_raddr,
	c_rdata,
	tiles_done,
	job_status
);
	reg _sv2v_0;
	localparam [31:0] tpu_pkg_N_PE = 4;
	parameter [31:0] N = tpu_pkg_N_PE;
	parameter [31:0] WD_W = 128;
	parameter [31:0] TAGW = 4;
	parameter [31:0] MAW = 10;
	parameter [31:0] DEPTH = 1024;
	input wire clk;
	input wire rst_n;
	input wire eng_valid;
	output wire eng_ready;
	input wire [WD_W - 1:0] eng_wd;
	input wire [TAGW - 1:0] eng_tag;
	output reg eng_done;
	output reg [TAGW - 1:0] eng_done_tag;
	input wire ld_we;
	input wire [1:0] ld_bank;
	input wire [MAW - 1:0] ld_addr;
	input wire [31:0] ld_data;
	output reg ld_refused;
	input wire [MAW - 1:0] c_raddr;
	output wire [31:0] c_rdata;
	output reg [15:0] tiles_done;
	output reg [2:0] job_status;
	localparam [31:0] tpu_pkg_KW = 16;
	wire [15:0] wd_m = eng_wd[116:101];
	wire [15:0] wd_k = eng_wd[84:69];
	wire [MAW - 1:0] base_a = eng_wd[3+:MAW];
	wire [MAW - 1:0] base_b = eng_wd[13+:MAW];
	wire [MAW - 1:0] base_c = eng_wd[23+:MAW];
	wire [15:0] wd_n = eng_wd[100:85];
	function automatic [15:0] sv2v_cast_9432F;
		input reg [15:0] inp;
		sv2v_cast_9432F = inp;
	endfunction
	wire core_will_run = ((((((eng_wd[127:124] == 4'd3) && (eng_wd[123:121] == 3'd0)) && (wd_m != {16 {1'sb0}})) && (wd_n != {16 {1'sb0}})) && (wd_k != {16 {1'sb0}})) && (wd_m <= sv2v_cast_9432F(N))) && (wd_n <= sv2v_cast_9432F(N));
	function automatic [16:0] sv2v_cast_2681B;
		input reg [16:0] inp;
		sv2v_cast_2681B = inp;
	endfunction
	wire in_range = ((({1'b0, sv2v_cast_9432F(base_a)} + {1'b0, wd_k}) <= sv2v_cast_2681B(DEPTH)) && (({1'b0, sv2v_cast_9432F(base_b)} + {1'b0, wd_k}) <= sv2v_cast_2681B(DEPTH))) && (({1'b0, sv2v_cast_9432F(base_c)} + sv2v_cast_2681B(N * N)) <= sv2v_cast_2681B(DEPTH));
	wire dma_busy;
	wire core_ready;
	reg done_pend_q;
	reg rej_pend_q;
	reg [TAGW - 1:0] pend_tag_q;
	assign eng_ready = ((core_ready && !dma_busy) && !done_pend_q) && !rej_pend_q;
	wire accept = eng_valid && eng_ready;
	wire refuse = (accept && core_will_run) && !in_range;
	wire to_core = accept && !refuse;
	wire run_job = to_core && core_will_run;
	wire [MAW - 1:0] dma_a_addr;
	wire [MAW - 1:0] dma_b_addr;
	wire [MAW - 1:0] dma_c_addr;
	wire [31:0] a_rdata;
	wire [31:0] b_rdata;
	wire [31:0] c_wdata;
	wire c_we;
	wire host_owns = eng_ready && !accept;
	wire a_ld_we = (ld_we && host_owns) && (ld_bank == 2'd0);
	wire b_ld_we = (ld_we && host_owns) && (ld_bank == 2'd1);
	wire c_ld_we = (ld_we && host_owns) && (ld_bank == 2'd2);
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			ld_refused <= 1'b0;
		else
			ld_refused <= ld_we && !host_owns;
	wire [MAW - 1:0] a_addr = (a_ld_we ? ld_addr : dma_a_addr);
	wire [MAW - 1:0] b_addr = (b_ld_we ? ld_addr : dma_b_addr);
	wire [MAW - 1:0] c_addr = (c_ld_we ? ld_addr : (c_we ? dma_c_addr : c_raddr));
	hydra_spram #(
		.DW(32),
		.DEPTH(DEPTH),
		.AW(MAW)
	) u_a(
		.clk(clk),
		.we(a_ld_we),
		.addr(a_addr),
		.wdata(ld_data),
		.rdata(a_rdata)
	);
	hydra_spram #(
		.DW(32),
		.DEPTH(DEPTH),
		.AW(MAW)
	) u_b(
		.clk(clk),
		.we(b_ld_we),
		.addr(b_addr),
		.wdata(ld_data),
		.rdata(b_rdata)
	);
	hydra_spram #(
		.DW(32),
		.DEPTH(DEPTH),
		.AW(MAW)
	) u_c(
		.clk(clk),
		.we(c_we || c_ld_we),
		.addr(c_addr),
		.wdata((c_ld_we ? ld_data : c_wdata)),
		.rdata(c_rdata)
	);
	wire op_valid;
	wire op_ready;
	wire [31:0] op_a_w;
	wire [31:0] op_b_w;
	wire res_valid;
	wire res_last;
	localparam [31:0] tpu_pkg_ACCW = 32;
	wire signed [31:0] res_data;
	wire [MAW - 1:0] dma_w_addr;
	wire [31:0] dma_op_w;
	hydra_dma_gemm #(
		.AW(MAW),
		.DW(32),
		.CNTW(tpu_pkg_KW)
	) u_dma(
		.clk(clk),
		.rst_n(rst_n),
		.start(run_job),
		.base_a(base_a),
		.base_b(base_b),
		.base_c(base_c),
		.k_slices(wd_k),
		.n_results(sv2v_cast_9432F(N * N)),
		.busy(dma_busy),
		.a_addr(dma_a_addr),
		.a_rdata(a_rdata),
		.b_addr(dma_b_addr),
		.b_rdata(b_rdata),
		.w_addr(dma_w_addr),
		.w_rdata(32'h00000000),
		.op_w(dma_op_w),
		.c_addr(dma_c_addr),
		.c_we(c_we),
		.c_wdata(c_wdata),
		.op_valid(op_valid),
		.op_ready(op_ready),
		.op_a(op_a_w),
		.op_b(op_b_w),
		.res_valid(res_valid),
		.res_data(res_data)
	);
	localparam [31:0] AW_LANE = 8;
	reg signed [(N * AW_LANE) - 1:0] op_a_lane;
	reg signed [(N * AW_LANE) - 1:0] op_b_lane;
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] l;
			for (l = 0; l < N; l = l + 1)
				begin
					op_a_lane[((N - 1) - l) * AW_LANE+:AW_LANE] = $signed(op_a_w[l * 8+:8]);
					op_b_lane[((N - 1) - l) * AW_LANE+:AW_LANE] = $signed(op_b_w[l * 8+:8]);
				end
		end
	end
	wire core_done;
	wire [TAGW - 1:0] core_done_tag;
	wire [1:0] core_status;
	tpu_top #(
		.N(N),
		.WD_W(WD_W),
		.TAGW(TAGW)
	) u_tpu(
		.clk(clk),
		.rst_n(rst_n),
		.eng_valid(to_core),
		.eng_ready(core_ready),
		.eng_wd(eng_wd),
		.eng_tag(eng_tag),
		.eng_done(core_done),
		.eng_done_tag(core_done_tag),
		.op_ready(op_ready),
		.op_valid(op_valid),
		.op_a(op_a_lane),
		.op_b(op_b_lane),
		.res_valid(res_valid),
		.res_data(res_data),
		.res_last(res_last),
		.status(core_status)
	);
	wire commit_ok = (done_pend_q && !dma_busy) && !res_valid;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			done_pend_q <= 1'b0;
			rej_pend_q <= 1'b0;
			pend_tag_q <= 1'sb0;
			eng_done <= 1'b0;
			eng_done_tag <= 1'sb0;
			job_status <= 3'd0;
			tiles_done <= 1'sb0;
		end
		else begin
			eng_done <= 1'b0;
			if (core_done) begin
				done_pend_q <= 1'b1;
				pend_tag_q <= core_done_tag;
				job_status <= {1'b0, core_status};
			end
			if (refuse) begin
				rej_pend_q <= 1'b1;
				pend_tag_q <= eng_tag;
				job_status <= 3'd4;
			end
			if (commit_ok || rej_pend_q) begin
				eng_done <= 1'b1;
				eng_done_tag <= pend_tag_q;
				done_pend_q <= 1'b0;
				rej_pend_q <= 1'b0;
				tiles_done <= tiles_done + 16'd1;
			end
		end
	wire _unused = &{res_last, dma_w_addr, dma_op_w, 1'b0};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_cpu_sram (
	clk,
	WRITE_ADDRESS,
	WRITE_MASK,
	WRITE_DATA,
	INSTRUCTION_REFILL_ADDRESS,
	INSTRUCTION_REFILL_LINE,
	DATA_REFILL_ADDRESS,
	DATA_REFILL_LINE,
	check_en
);
	reg _sv2v_0;
	parameter signed [31:0] LINES = 512;
	parameter [0:0] MACROS = 1'b1;
	input wire clk;
	input wire [15:0] WRITE_ADDRESS;
	input wire [7:0] WRITE_MASK;
	input wire [63:0] WRITE_DATA;
	input wire [15:0] INSTRUCTION_REFILL_ADDRESS;
	output wire [255:0] INSTRUCTION_REFILL_LINE;
	input wire [15:0] DATA_REFILL_ADDRESS;
	output wire [255:0] DATA_REFILL_LINE;
	input wire check_en;
	localparam signed [31:0] IB = $clog2(LINES);
	localparam signed [31:0] NB = LINES / 512;
	localparam signed [31:0] BB = (NB > 1 ? $clog2(NB) : 1);
	wire [IB - 1:0] w_idx = WRITE_ADDRESS[IB + 4:5];
	wire [IB - 1:0] i_idx = INSTRUCTION_REFILL_ADDRESS[IB + 4:5];
	wire [IB - 1:0] d_idx = DATA_REFILL_ADDRESS[IB + 4:5];
	wire [1:0] w_dw = WRITE_ADDRESS[4:3];
	reg [3:0] lane_we [0:7];
	reg [31:0] lane_wdat [0:7];
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	always @(*) begin : sv2v_autoblock_1
		reg signed [31:0] l;
		if (_sv2v_0)
			;
		for (l = 0; l < 8; l = l + 1)
			begin
				lane_we[l] = ((l / 2) == sv2v_cast_32_signed(w_dw) ? ((l % 2) == 1 ? WRITE_MASK[7:4] : WRITE_MASK[3:0]) : 4'd0);
				lane_wdat[l] = ((l % 2) == 1 ? WRITE_DATA[63:32] : WRITE_DATA[31:0]);
			end
	end
	reg [IB - 1:0] last_idx;
	reg [3:0] last_we [0:7];
	reg [31:0] last_wdat [0:7];
	reg [IB - 1:0] i_idx_q;
	reg [IB - 1:0] d_idx_q;
	always @(posedge clk) begin
		last_idx <= w_idx;
		i_idx_q <= i_idx;
		d_idx_q <= d_idx;
		begin : sv2v_autoblock_2
			reg signed [31:0] l;
			for (l = 0; l < 8; l = l + 1)
				begin
					last_we[l] <= lane_we[l];
					last_wdat[l] <= lane_wdat[l];
				end
		end
	end
	function automatic [31:0] merge;
		input reg [31:0] old;
		input reg [3:0] we;
		input reg [31:0] d;
		reg signed [31:0] b;
		for (b = 0; b < 4; b = b + 1)
			merge[8 * b+:8] = (we[b] ? d[8 * b+:8] : old[8 * b+:8]);
	endfunction
	wire _unused_addr = &{1'b0, WRITE_ADDRESS, INSTRUCTION_REFILL_ADDRESS, DATA_REFILL_ADDRESS};
	genvar _gv_L_1;
	genvar _gv_B_1;
	function automatic signed [BB - 1:0] sv2v_cast_01BB7_signed;
		input reg signed [BB - 1:0] inp;
		sv2v_cast_01BB7_signed = inp;
	endfunction
	generate
		for (_gv_L_1 = 0; _gv_L_1 < 8; _gv_L_1 = _gv_L_1 + 1) begin : g_lane
			localparam L = _gv_L_1;
			wire writing = |lane_we[L];
			reg rd0_q;
			reg [31:0] held_q;
			wire [31:0] p0_word;
			wire [31:0] p1_word;
			wire [31:0] p0_dout [0:NB - 1];
			wire [31:0] p1_dout [0:NB - 1];
			for (_gv_B_1 = 0; _gv_B_1 < NB; _gv_B_1 = _gv_B_1 + 1) begin : g_bank
				localparam B = _gv_B_1;
				wire sel_w = (NB == 1) || (w_idx[IB - 1-:BB] == sv2v_cast_01BB7_signed(B));
				wire sel_d = (NB == 1) || (d_idx[IB - 1-:BB] == sv2v_cast_01BB7_signed(B));
				wire sel_i = (NB == 1) || (i_idx[IB - 1-:BB] == sv2v_cast_01BB7_signed(B));
				wire csb0 = !(writing ? sel_w : sel_d);
				wire web0 = !writing;
				wire [8:0] addr0 = (writing ? w_idx[8:0] : d_idx[8:0]);
				wire csb1 = !sel_i;
				if (MACROS) begin : g_macro
					sky130_sram_2kbyte_1rw1r_32x512_8 u_ram(
						.clk0(clk),
						.csb0(csb0),
						.web0(web0),
						.wmask0(lane_we[L]),
						.addr0(addr0),
						.din0(lane_wdat[L]),
						.dout0(p0_dout[B]),
						.clk1(clk),
						.csb1(csb1),
						.addr1(i_idx[8:0]),
						.dout1(p1_dout[B])
					);
				end
				else begin : g_model
					hydra_sram_1rw1r_512x32 u_ram(
						.clk(clk),
						.csb0(csb0),
						.web0(web0),
						.wmask0(lane_we[L]),
						.addr0(addr0),
						.din0(lane_wdat[L]),
						.dout0(p0_dout[B]),
						.csb1(csb1),
						.addr1(i_idx[8:0]),
						.dout1(p1_dout[B])
					);
				end
			end
			if (NB == 1) begin : g_one
				assign p0_word = p0_dout[0];
				assign p1_word = p1_dout[0];
			end
			else begin : g_many
				assign p0_word = p0_dout[d_idx_q[IB - 1-:BB]];
				assign p1_word = p1_dout[i_idx_q[IB - 1-:BB]];
			end
			assign INSTRUCTION_REFILL_LINE[32 * L+:32] = (i_idx_q == last_idx ? merge(p1_word, last_we[L], last_wdat[L]) : p1_word);
			wire [31:0] d_word = (rd0_q ? p0_word : held_q);
			assign DATA_REFILL_LINE[32 * L+:32] = d_word;
			always @(posedge clk) begin
				rd0_q <= !writing;
				held_q <= (writing && (w_idx == d_idx) ? merge(d_word, lane_we[L], lane_wdat[L]) : d_word);
			end
		end
	endgenerate
	initial _sv2v_0 = 0;
endmodule
module hydra_sram_1rw1r_512x32 (
	clk,
	csb0,
	web0,
	wmask0,
	addr0,
	din0,
	dout0,
	csb1,
	addr1,
	dout1
);
	input wire clk;
	input wire csb0;
	input wire web0;
	input wire [3:0] wmask0;
	input wire [8:0] addr0;
	input wire [31:0] din0;
	output reg [31:0] dout0;
	input wire csb1;
	input wire [8:0] addr1;
	output reg [31:0] dout1;
	reg [31:0] mem [0:511];
	always @(posedge clk) begin
		if (!csb0 && !web0) begin : sv2v_autoblock_1
			reg signed [31:0] b;
			for (b = 0; b < 4; b = b + 1)
				if (wmask0[b])
					mem[addr0][8 * b+:8] <= din0[8 * b+:8];
		end
		if (!csb0 && web0)
			dout0 <= mem[addr0];
		if (!csb1)
			dout1 <= mem[addr1];
	end
endmodule
`default_nettype wire
`default_nettype none
module hydra_engine_cpu (
	clk,
	rst_n,
	eng_valid,
	eng_ready,
	eng_wd,
	eng_tag,
	eng_done,
	eng_done_tag,
	job_status,
	tohost,
	disp_valid,
	disp_wd,
	disp_hdr,
	disp_taken,
	disp_status,
	ld_we,
	ld_addr,
	ld_data,
	ld_refused,
	rd_addr,
	rd_data,
	dbg_reg,
	dbg_data,
	cfg_we,
	cfg_addr,
	cfg_data,
	perf_cycles,
	uart_tx,
	uart_idle,
	gpio_out,
	gpio_in
);
	parameter [31:0] TAGW = 4;
	parameter [31:0] MEM_BYTES = 65536;
	parameter [0:0] SRAM = 1'b0;
	parameter [31:0] CACHE_SETS = 64;
	parameter [0:0] SRAM_MODEL = 1'b0;
	parameter [0:0] CACHED = 1'b0;
	parameter [31:0] MISS_LATENCY = 10;
	parameter [31:0] UART_DIV = 16;
	parameter [31:0] UART_FIFO = 16;
	input wire clk;
	input wire rst_n;
	input wire eng_valid;
	output wire eng_ready;
	input wire [127:0] eng_wd;
	input wire [TAGW - 1:0] eng_tag;
	output reg eng_done;
	output reg [TAGW - 1:0] eng_done_tag;
	output reg [1:0] job_status;
	output reg [63:0] tohost;
	output reg disp_valid;
	output reg [127:0] disp_wd;
	output reg [63:0] disp_hdr;
	input wire disp_taken;
	input wire [63:0] disp_status;
	input wire ld_we;
	input wire [13:0] ld_addr;
	input wire [31:0] ld_data;
	output reg ld_refused;
	input wire [13:0] rd_addr;
	output reg [31:0] rd_data;
	input wire [4:0] dbg_reg;
	output wire [63:0] dbg_data;
	input wire cfg_we;
	input wire cfg_addr;
	input wire [31:0] cfg_data;
	output reg [31:0] perf_cycles;
	output reg uart_tx;
	output wire uart_idle;
	output reg [15:0] gpio_out;
	input wire [15:0] gpio_in;
	localparam [63:0] MMIO_BASE = 64'h0000000010000000;
	localparam [63:0] MMIO_PUTCHAR = 64'h0000000010000000;
	localparam [63:0] MMIO_LEDS = 64'h0000000010000008;
	localparam [63:0] MMIO_BUTTONS = 64'h0000000010000010;
	localparam [63:0] MMIO_UART_DIV = 64'h0000000010000080;
	localparam [63:0] MMIO_UART_ST = 64'h0000000010000088;
	localparam [63:0] MMIO_MTIME = 64'h0000000010000058;
	localparam [63:0] MMIO_MTIMECMP = 64'h0000000010000060;
	localparam [63:0] MMIO_DESC_LO = 64'h0000000010000100;
	localparam [63:0] MMIO_DESC_HI = 64'h0000000010000108;
	localparam [63:0] MMIO_HDR = 64'h0000000010000110;
	localparam [63:0] MMIO_SUBMIT = 64'h0000000010000118;
	localparam [63:0] MMIO_STATUS = 64'h0000000010000120;
	localparam [1:0] ST_OK = 2'd0;
	localparam [1:0] ST_REFUSED = 2'd1;
	localparam [1:0] ST_LIMIT = 2'd2;
	reg [1:0] st;
	reg loaded;
	reg [31:0] entry;
	reg [31:0] limit;
	reg [31:0] count;
	reg [TAGW - 1:0] tag_q;
	wire HALTED;
	wire [63:0] csr_tohost;
	assign eng_ready = (st == 2'd0) || (st == 2'd3);
	wire accept = eng_valid && eng_ready;
	wire malformed = (!loaded || (entry[1:0] != 2'd0)) || (entry >= MEM_BYTES);
	wire core_reset = (st == 2'd0) || (st == 2'd1);
	wire host_owns = eng_ready && !accept;
	wire [63:0] icache_addr;
	wire [63:0] dcache_addr;
	wire [63:0] dcache_din;
	wire [7:0] dcache_we;
	wire dcache_re;
	wire [31:0] icache_dout;
	wire icache_hit;
	wire dcache_hit;
	wire [63:0] mem_dout;
	wire is_dev = dcache_addr[63:8] == MMIO_BASE[63:8];
	wire host_we = ld_we && host_owns;
	wire core_store_ok = ((st == 2'd2) && !HALTED) && !is_dev;
	reg [63:0] mtime;
	reg [63:0] mtimecmp;
	always @(posedge clk)
		if (core_reset) begin
			mtime <= 64'd0;
			mtimecmp <= 1'sb1;
		end
		else begin
			mtime <= mtime + 64'd1;
			if (dcache_addr == MMIO_MTIMECMP) begin : sv2v_autoblock_1
				reg signed [31:0] b;
				for (b = 0; b < 8; b = b + 1)
					if (dcache_we[b])
						mtimecmp[8 * b+:8] <= dcache_din[8 * b+:8];
			end
		end
	wire disp_store = ((st == 2'd2) && !HALTED) && (dcache_we != 8'd0);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			disp_valid <= 1'b0;
			disp_wd <= 1'sb0;
			disp_hdr <= 1'sb0;
		end
		else begin
			if (disp_taken)
				disp_valid <= 1'b0;
			if (disp_store) begin
				begin : sv2v_autoblock_2
					reg signed [31:0] b;
					for (b = 0; b < 8; b = b + 1)
						if (dcache_we[b]) begin
							if (dcache_addr == MMIO_DESC_LO)
								disp_wd[8 * b+:8] <= dcache_din[8 * b+:8];
							if (dcache_addr == MMIO_DESC_HI)
								disp_wd[64 + (8 * b)+:8] <= dcache_din[8 * b+:8];
							if (dcache_addr == MMIO_HDR)
								disp_hdr[8 * b+:8] <= dcache_din[8 * b+:8];
						end
				end
				if ((dcache_addr == MMIO_SUBMIT) && !disp_valid)
					disp_valid <= 1'b1;
			end
		end
	localparam signed [31:0] QW = $clog2(UART_FIFO);
	wire dev_store = disp_store;
	reg [7:0] uq [0:UART_FIFO - 1];
	reg [QW:0] uq_wp;
	reg [QW:0] uq_rp;
	reg [15:0] uart_div;
	reg [7:0] uart_dropped;
	reg [9:0] tx_shift;
	reg [3:0] tx_bits;
	reg [15:0] tx_count;
	reg [31:0] btn_sync;
	wire uq_empty = uq_wp == uq_rp;
	wire uq_full = (uq_wp[QW - 1:0] == uq_rp[QW - 1:0]) && (uq_wp[QW] != uq_rp[QW]);
	wire put_now = (dev_store && (dcache_addr == MMIO_PUTCHAR)) && dcache_we[0];
	assign uart_idle = uq_empty && (tx_bits == 4'd0);
	function automatic [15:0] sv2v_cast_16;
		input reg [15:0] inp;
		sv2v_cast_16 = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			uq_wp <= 1'sb0;
			uq_rp <= 1'sb0;
			uart_div <= sv2v_cast_16(UART_DIV);
			uart_dropped <= 1'sb0;
			tx_shift <= 1'sb1;
			tx_bits <= 1'sb0;
			tx_count <= 1'sb0;
			uart_tx <= 1'b1;
			gpio_out <= 1'sb0;
			btn_sync <= 1'sb0;
		end
		else begin
			btn_sync <= {btn_sync[0+:16], gpio_in};
			if (put_now) begin
				if (uq_full)
					uart_dropped <= uart_dropped + {7'd0, uart_dropped != 8'hff};
				else begin
					uq[uq_wp[QW - 1:0]] <= dcache_din[7:0];
					uq_wp <= uq_wp + 1'b1;
				end
			end
			if (dev_store && (dcache_addr == MMIO_UART_DIV)) begin
				if (dcache_we[0])
					uart_div[7:0] <= dcache_din[7:0];
				if (dcache_we[1])
					uart_div[15:8] <= dcache_din[15:8];
			end
			if (dev_store && (dcache_addr == MMIO_LEDS)) begin
				if (dcache_we[0])
					gpio_out[7:0] <= dcache_din[7:0];
				if (dcache_we[1])
					gpio_out[15:8] <= dcache_din[15:8];
			end
			if (tx_bits == 4'd0) begin
				if (!uq_empty) begin
					tx_shift <= {1'b1, uq[uq_rp[QW - 1:0]], 1'b0};
					uq_rp <= uq_rp + 1'b1;
					tx_bits <= 4'd10;
					tx_count <= 1'sb0;
				end
			end
			else if ((tx_count + 16'd1) >= uart_div) begin
				tx_count <= 1'sb0;
				tx_shift <= {1'b1, tx_shift[9:1]};
				tx_bits <= tx_bits - 4'd1;
			end
			else
				tx_count <= tx_count + 16'd1;
			uart_tx <= (tx_bits == 4'd0 ? 1'b1 : tx_shift[0]);
		end
	wire [63:0] dev_dout = (dcache_addr == MMIO_MTIME ? mtime : (dcache_addr == MMIO_BUTTONS ? {48'd0, btn_sync[16+:16]} : (dcache_addr == MMIO_UART_DIV ? {48'd0, uart_div} : (dcache_addr == MMIO_UART_ST ? {48'd0, uart_dropped, 6'd0, uq_full, !uart_idle} : (dcache_addr == MMIO_MTIMECMP ? mtimecmp : (dcache_addr == MMIO_STATUS ? {disp_status[63:1], disp_valid} : 64'd0))))));
	wire [63:0] dcache_dout = ((((((dcache_addr == MMIO_MTIME) || (dcache_addr == MMIO_MTIMECMP)) || (dcache_addr == MMIO_STATUS)) || (dcache_addr == MMIO_BUTTONS)) || (dcache_addr == MMIO_UART_DIV)) || (dcache_addr == MMIO_UART_ST) ? dev_dout : mem_dout);
	function automatic signed [15:0] sv2v_cast_16_signed;
		input reg signed [15:0] inp;
		sv2v_cast_16_signed = inp;
	endfunction
	generate
		if (!CACHED) begin : g_flat
			reg [7:0] mem [0:MEM_BYTES - 1];
			wire [15:0] ia = icache_addr[15:0];
			wire [15:0] da = {dcache_addr[15:3], 3'b000};
			assign icache_dout = {mem[ia + 16'd3], mem[ia + 16'd2], mem[ia + 16'd1], mem[ia]};
			assign icache_hit = 1'b1;
			assign dcache_hit = 1'b1;
			assign mem_dout = (is_dev ? 64'd0 : {mem[da + 16'd7], mem[da + 16'd6], mem[da + 16'd5], mem[da + 16'd4], mem[da + 16'd3], mem[da + 16'd2], mem[da + 16'd1], mem[da]});
			always @(posedge clk) begin
				if (host_we) begin : sv2v_autoblock_3
					reg signed [31:0] b;
					for (b = 0; b < 4; b = b + 1)
						mem[{ld_addr, 2'b00} + sv2v_cast_16_signed(b)] <= ld_data[8 * b+:8];
				end
				else if (core_store_ok) begin : sv2v_autoblock_4
					reg signed [31:0] b;
					for (b = 0; b < 8; b = b + 1)
						if (dcache_we[b])
							mem[da + sv2v_cast_16_signed(b)] <= dcache_din[8 * b+:8];
				end
				rd_data <= {mem[{rd_addr, 2'b11}], mem[{rd_addr, 2'b10}], mem[{rd_addr, 2'b01}], mem[{rd_addr, 2'b00}]};
			end
		end
		else begin : g_cached
			wire [63:0] irefill_addr;
			wire [63:0] drefill_addr;
			wire [255:0] irefill_line;
			wire [255:0] drefill_line;
			wire [63:0] cache_data;
			InstructionCache #(
				.MISS_LATENCY(MISS_LATENCY),
				.SETS(CACHE_SETS)
			) u_icache(
				.clk(clk),
				.reset(core_reset),
				.FREEZE(HALTED),
				.FETCH_ADDRESS(icache_addr),
				.INSTRUCTION(icache_dout),
				.HIT(icache_hit),
				.REFILL_ADDRESS(irefill_addr),
				.REFILL_LINE(irefill_line)
			);
			DataCache #(
				.MISS_LATENCY(MISS_LATENCY),
				.SETS(CACHE_SETS)
			) u_dcache(
				.clk(clk),
				.reset(core_reset),
				.FREEZE(HALTED),
				.LOAD_REQUEST(dcache_re),
				.ADDRESS(dcache_addr),
				.WRITE_MASK(dcache_we),
				.WRITE_DATA(dcache_din),
				.READ_DATA(cache_data),
				.HIT(dcache_hit),
				.REFILL_ADDRESS(drefill_addr),
				.REFILL_LINE(drefill_line)
			);
			assign mem_dout = (is_dev ? 64'd0 : cache_data);
			wire [15:0] host_byte = {ld_addr, 2'b00};
			wire [15:0] w_addr = (host_we ? {host_byte[15:3], 3'b000} : dcache_addr[15:0]);
			wire [7:0] w_mask = (host_we ? (host_byte[2] ? 8'hf0 : 8'h0f) : (core_store_ok ? dcache_we : 8'h00));
			wire [63:0] w_data = (host_we ? {ld_data, ld_data} : dcache_din);
			wire [15:0] rd_byte = {rd_addr, 2'b00};
			wire [15:0] d_refill = (st == 2'd2 ? drefill_addr[15:0] : rd_byte);
			wire _unused_hi = &{1'b0, irefill_addr[63:16], drefill_addr[63:16], host_byte[1:0]};
			if (SRAM) begin : g_sram
				hydra_cpu_sram #(
					.LINES(MEM_BYTES / 32),
					.MACROS(!SRAM_MODEL)
				) u_mem(
					.clk(clk),
					.WRITE_ADDRESS(w_addr),
					.WRITE_MASK(w_mask),
					.WRITE_DATA(w_data),
					.INSTRUCTION_REFILL_ADDRESS(irefill_addr[15:0]),
					.INSTRUCTION_REFILL_LINE(irefill_line),
					.DATA_REFILL_ADDRESS(d_refill),
					.DATA_REFILL_LINE(drefill_line),
					.check_en(st == 2'd2)
				);
			end
			else begin : g_bram
				MainMemory #(.LINES(MEM_BYTES / 32)) u_mem(
					.clk(clk),
					.WRITE_ADDRESS(w_addr),
					.WRITE_MASK(w_mask),
					.WRITE_DATA(w_data),
					.INSTRUCTION_REFILL_ADDRESS(irefill_addr[15:0]),
					.INSTRUCTION_REFILL_LINE(irefill_line),
					.DATA_REFILL_ADDRESS(d_refill),
					.DATA_REFILL_LINE(drefill_line)
				);
			end
			reg [2:0] rd_word_q;
			always @(posedge clk) rd_word_q <= rd_byte[4:2];
			wire [32:1] sv2v_tmp_4E9D2;
			assign sv2v_tmp_4E9D2 = drefill_line[32 * rd_word_q+:32];
			always @(*) rd_data = sv2v_tmp_4E9D2;
		end
	endgenerate
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			ld_refused <= 1'b0;
		else
			ld_refused <= ld_we && !host_owns;
	Riscv64 #(
		.GSHARE_HISTORY_BITS(6),
		.BTB_ENABLE(1'b1),
		.RAS_ENABLE(1'b1),
		.PRECISE_LOAD_STALL(1'b1),
		.ITERATIVE_MULTIPLY_DIVIDE(1'b1),
		.TOURNAMENT_PREDICTOR(1'b1)
	) u_core(
		.clk(clk),
		.reset(core_reset),
		.BRANCH_PREDICTION_ENABLE(1'b1),
		.RESET_VECTOR({32'd0, entry}),
		.TIMER_INTERRUPT_LINE(mtime >= mtimecmp),
		.EXTERNAL_INTERRUPT_LINE(1'b0),
		.dcache_addr(dcache_addr),
		.icache_addr(icache_addr),
		.dcache_we(dcache_we),
		.dcache_din(dcache_din),
		.dcache_dout(dcache_dout),
		.icache_dout(icache_dout),
		.icache_hit(icache_hit),
		.dcache_re(dcache_re),
		.dcache_hit(dcache_hit),
		.csr(csr_tohost),
		.HALTED(HALTED),
		.DEBUG_REGISTER_ADDRESS(dbg_reg),
		.DEBUG_REGISTER_DATA(dbg_data),
		.TRACE_VALID(),
		.TRACE_FETCH1_PC(),
		.TRACE_FETCH2_PC(),
		.TRACE_DECODE_PC(),
		.TRACE_EXECUTE_PC(),
		.TRACE_MEMORY_PC(),
		.TRACE_WRITEBACK_PC(),
		.TRACE_LOAD_STALL(),
		.TRACE_FLUSH(),
		.TRACE_REDIRECT(),
		.TRACE_MULTIPLY_DIVIDE_STALL(),
		.TRACE_INSTRUCTION_MISS(),
		.TRACE_DATA_MISS()
	);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			st <= 2'd0;
			loaded <= 1'b0;
			entry <= 32'h00002000;
			limit <= 32'd4000000;
			count <= 1'sb0;
			tag_q <= 1'sb0;
			eng_done <= 1'b0;
			eng_done_tag <= 1'sb0;
			job_status <= ST_OK;
			tohost <= 1'sb0;
			perf_cycles <= 1'sb0;
		end
		else begin
			eng_done <= 1'b0;
			if (host_we)
				loaded <= 1'b1;
			if (cfg_we && eng_ready) begin
				if (cfg_addr)
					limit <= cfg_data;
				else
					entry <= cfg_data;
			end
			(* full_case, parallel_case *)
			case (st)
				2'd0, 2'd3:
					if (accept) begin
						tag_q <= eng_tag;
						if (malformed) begin
							eng_done <= 1'b1;
							eng_done_tag <= eng_tag;
							job_status <= ST_REFUSED;
						end
						else
							st <= 2'd1;
					end
				2'd1: begin
					count <= 1'sb0;
					st <= 2'd2;
				end
				2'd2: begin
					count <= count + 32'd1;
					if (HALTED) begin
						eng_done <= 1'b1;
						eng_done_tag <= tag_q;
						job_status <= ST_OK;
						tohost <= csr_tohost;
						perf_cycles <= count;
						st <= 2'd3;
					end
					else if ((count + 32'd1) >= limit) begin
						eng_done <= 1'b1;
						eng_done_tag <= tag_q;
						job_status <= ST_LIMIT;
						tohost <= 1'sb0;
						perf_cycles <= count;
						st <= 2'd0;
					end
				end
				default: st <= 2'd0;
			endcase
		end
	wire _unused = &{eng_wd, dcache_re, disp_status[0], 1'b0};
endmodule
`default_nettype wire
`default_nettype none
module hydra_abi_v2 (
	clk,
	rst_n,
	in_valid,
	in_ready,
	in_hdr,
	in_body,
	out_valid,
	out_ready,
	out_body,
	out_elig,
	sched_done,
	err_valid,
	err_code,
	err_tag,
	ctx_we,
	ctx_id,
	ctx_owned,
	ctx_epoch,
	healthy
);
	reg _sv2v_0;
	localparam [31:0] mom_pkg_ENG_N_CHIP = 6;
	parameter [31:0] NENG = mom_pkg_ENG_N_CHIP;
	parameter [31:0] NCTX = 16;
	parameter [7:0] PRESENT = 8'b00111111;
	input wire clk;
	input wire rst_n;
	input wire in_valid;
	output wire in_ready;
	input wire [63:0] in_hdr;
	localparam [31:0] mom_pkg_WD_W = 128;
	input wire [127:0] in_body;
	output reg out_valid;
	input wire out_ready;
	output reg [127:0] out_body;
	output reg [NENG - 1:0] out_elig;
	input wire sched_done;
	output reg err_valid;
	output reg [3:0] err_code;
	output reg [7:0] err_tag;
	input wire ctx_we;
	input wire [7:0] ctx_id;
	input wire ctx_owned;
	input wire [15:0] ctx_epoch;
	input wire [NENG - 1:0] healthy;
	localparam [3:0] E_OK = 4'd0;
	localparam [3:0] E_VERSION = 4'd1;
	localparam [3:0] E_RESERVED = 4'd2;
	localparam [3:0] E_MODE = 4'd3;
	localparam [3:0] E_POLICY = 4'd4;
	localparam [3:0] E_CONTEXT = 4'd5;
	localparam [3:0] E_KEY = 4'd6;
	localparam [3:0] E_NO_ENGINE = 4'd7;
	wire [3:0] h_ver = in_hdr[63:60];
	wire [1:0] h_mode = in_hdr[59:58];
	wire [2:0] h_pol = in_hdr[57:55];
	wire [7:0] h_ctx = in_hdr[54:47];
	wire [15:0] h_epoch = in_hdr[46:31];
	wire [7:0] h_key = in_hdr[30:23];
	wire [7:0] h_prof = in_hdr[22:15];
	wire [14:0] h_rsvd = in_hdr[14:0];
	reg [NCTX - 1:0] owned;
	reg [15:0] epoch [0:NCTX - 1];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			owned <= 1'sb0;
			begin : sv2v_autoblock_1
				reg signed [31:0] i;
				for (i = 0; i < NCTX; i = i + 1)
					epoch[i] <= 1'sb0;
			end
		end
		else if (ctx_we && ({24'd0, ctx_id} < NCTX)) begin
			owned[ctx_id[$clog2(NCTX) - 1:0]] <= ctx_owned;
			epoch[ctx_id[$clog2(NCTX) - 1:0]] <= ctx_epoch;
		end
	wire ctx_in_range = {24'd0, h_ctx} < NCTX;
	wire ctx_ok = (ctx_in_range && owned[h_ctx[$clog2(NCTX) - 1:0]]) && (epoch[h_ctx[$clog2(NCTX) - 1:0]] == h_epoch);
	localparam signed [31:0] GPU_SLOT = (NENG > 32'sd5 ? 32'sd5 : 0);
	function automatic [NENG - 1:0] policy_mask;
		input reg [2:0] p;
		reg [NENG - 1:0] m;
		begin
			m = 1'sb0;
			(* full_case, parallel_case *)
			case (p)
				3'd0: m = 1'sb1;
				3'd1: m[3'd0] = 1'b1;
				3'd2:
					if (NENG > 32'sd5)
						m[GPU_SLOT] = 1'b1;
				3'd3: m[3'd2] = 1'b1;
				3'd4: m[3'd1] = 1'b1;
				3'd5: m[3'd3] = 1'b1;
				default: m = 1'sb0;
			endcase
			policy_mask = m;
		end
	endfunction
	wire [NENG - 1:0] elig = (policy_mask(h_pol) & PRESENT[NENG - 1:0]) & healthy;
	reg [3:0] verdict;
	always @(*) begin
		if (_sv2v_0)
			;
		if (h_ver != 4'd2)
			verdict = E_VERSION;
		else if (h_rsvd != 15'd0)
			verdict = E_RESERVED;
		else if (h_mode != 2'd0)
			verdict = E_MODE;
		else if (h_pol > 3'd5)
			verdict = E_POLICY;
		else if (!ctx_ok)
			verdict = E_CONTEXT;
		else if ((h_key != 8'd0) || (h_prof != 8'd0))
			verdict = E_KEY;
		else if (elig == {NENG {1'sb0}})
			verdict = E_NO_ENGINE;
		else
			verdict = E_OK;
	end
	reg [1:0] st;
	assign in_ready = st == 2'd0;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			st <= 2'd0;
			out_valid <= 1'b0;
			out_body <= 1'sb0;
			out_elig <= 1'sb0;
			err_valid <= 1'b0;
			err_code <= E_OK;
			err_tag <= 1'sb0;
		end
		else begin
			err_valid <= 1'b0;
			(* full_case, parallel_case *)
			case (st)
				2'd0:
					if (in_valid) begin
						if (verdict != E_OK) begin
							err_valid <= 1'b1;
							err_code <= verdict;
							err_tag <= in_body[42:35];
						end
						else begin
							out_body <= in_body;
							out_elig <= elig;
							out_valid <= 1'b1;
							st <= 2'd1;
						end
					end
				2'd1:
					if (out_ready) begin
						out_valid <= 1'b0;
						st <= 2'd2;
					end
				2'd2:
					if (sched_done)
						st <= 2'd0;
				default: st <= 2'd0;
			endcase
		end
	wire _unused = &{h_key, h_prof, 1'b0};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_sys_tile (
	ui_in,
	uo_out,
	uio_in,
	uio_out,
	uio_oe,
	ena,
	clk,
	rst_n,
	dbg_checksum,
	dbg_tiles,
	dbg_simd_checksum,
	dbg_simd_jobs,
	mem_we,
	mem_bank,
	mem_addr,
	mem_wdata,
	mem_raddr,
	mem_rdata,
	mem_refused,
	cpu_uart_tx,
	cpu_gpio_out,
	cpu_gpio_in
);
	reg _sv2v_0;
	parameter [31:0] NTAG = 8;
	parameter [31:0] NENG = 5;
	parameter [31:0] LAT_FAST = 30;
	parameter [31:0] LAT_SLOW = 2000;
	parameter [31:0] TPU_ENGINE = 0;
	parameter [31:0] SIMD_ENGINE = 0;
	parameter [31:0] GPU_ENGINE = 0;
	parameter [31:0] ABI_V2 = 0;
	parameter [31:0] CPU_ENGINE = 0;
	parameter [31:0] SECURE_BOOT = 0;
	parameter [31:0] CPU_CACHED = 1;
	parameter [31:0] CPU_SRAM = 0;
	parameter [31:0] CPU_SRAM_MODEL = 0;
	parameter [31:0] CPU_MEM_BYTES = 65536;
	parameter [31:0] CPU_CACHE_SETS = 64;
	parameter [255:0] BOOT_GOLDEN = 256'd0;
	input wire [7:0] ui_in;
	output wire [7:0] uo_out;
	input wire [7:0] uio_in;
	output wire [7:0] uio_out;
	output wire [7:0] uio_oe;
	input wire ena;
	input wire clk;
	input wire rst_n;
	output wire [31:0] dbg_checksum;
	output wire [15:0] dbg_tiles;
	output wire [31:0] dbg_simd_checksum;
	output wire [15:0] dbg_simd_jobs;
	input wire mem_we;
	input wire [1:0] mem_bank;
	input wire [15:0] mem_addr;
	input wire [31:0] mem_wdata;
	input wire [15:0] mem_raddr;
	output wire [31:0] mem_rdata;
	output wire mem_refused;
	output wire cpu_uart_tx;
	output wire [15:0] cpu_gpio_out;
	input wire [15:0] cpu_gpio_in;
	reg [13:0] pins_meta;
	reg [13:0] pins_q;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			pins_meta <= 1'sb0;
			pins_q <= 1'sb0;
		end
		else begin
			pins_meta <= {ena, ui_in[7:3], uio_in};
			pins_q <= pins_meta;
		end
	localparam [31:0] TPU_MODEL = 0;
	localparam [31:0] TPU_PATTERN = 1;
	localparam [31:0] TPU_MEMORY = 2;
	localparam [31:0] SIMD_MODEL = 0;
	localparam [31:0] SIMD_PATTERN = 1;
	localparam [0:0] REAL_TPU = TPU_ENGINE == TPU_PATTERN;
	localparam [0:0] TPU_FROM_MEM = TPU_ENGINE == TPU_MEMORY;
	localparam [0:0] REAL_SIMD = SIMD_ENGINE == SIMD_PATTERN;
	localparam [0:0] REAL_GPU = (GPU_ENGINE == 1) && (NENG > 5);
	generate
		if (TPU_ENGINE > TPU_MEMORY) begin : g_bad_tpu_engine
			hydra_sys_tile_unknown_TPU_ENGINE u_bad();
		end
		if (SIMD_ENGINE > SIMD_PATTERN) begin : g_bad_simd_engine
			hydra_sys_tile_unknown_SIMD_ENGINE u_bad();
		end
		if ((GPU_ENGINE > 1) || ((GPU_ENGINE == 1) && (NENG < 6))) begin : g_bad_gpu_engine
			hydra_sys_tile_GPU_ENGINE_needs_NENG_6 u_bad();
		end
	endgenerate
	wire cs_start;
	wire cs_end;
	wire cs_active;
	wire rx_valid;
	wire tx_load;
	wire cipo;
	wire [7:0] rx_byte;
	wire [7:0] tx_byte;
	wire [4:0] rx_index;
	hydra_tt_spi u_spi(
		.clk(clk),
		.rst_n(rst_n),
		.sck_i(ui_in[0]),
		.copi_i(ui_in[1]),
		.csn_i(ui_in[2]),
		.cipo_o(cipo),
		.cs_start(cs_start),
		.cs_end(cs_end),
		.cs_active(cs_active),
		.rx_valid(rx_valid),
		.rx_byte(rx_byte),
		.rx_index(rx_index),
		.tx_load(tx_load),
		.tx_byte(tx_byte)
	);
	wire wd_valid;
	wire wd_ready;
	localparam [31:0] mom_pkg_WD_W = 128;
	wire [127:0] wd;
	wire s_wd_valid;
	wire s_wd_ready;
	wire [127:0] s_wd;
	wire [NENG - 1:0] s_elig;
	wire abi_err;
	wire [7:0] abi_err_tag;
	wire m_err_unsupported;
	wire [7:0] m_err_tag;
	wire disp_valid;
	wire disp_accept;
	wire [2:0] disp_engine;
	wire [3:0] disp_tag;
	wire [127:0] disp_wd;
	wire comp_valid;
	wire [3:0] comp_tag;
	wire err_unsupported;
	wire err_stale_comp;
	wire fence_busy;
	wire [7:0] err_tag;
	localparam [31:0] mom_pkg_COST_W = 32;
	wire [31:0] obs_margin;
	wire [15:0] obs_cal_updates;
	wire [NTAG - 1:0] obs_tag_busy;
	wire r_csr_wr;
	wire r_csr_priv;
	wire r_cal_freeze;
	wire r_cal_reset;
	wire [2:0] r_csr_engine;
	localparam [31:0] mom_pkg_EPARAM_W = 43;
	wire [42:0] r_csr_data;
	wire [3:0] r_bw;
	wire [3:0] r_eps;
	wire [3:0] r_esh;
	wire [3:0] r_fence_tag;
	wire [3:0] r_last_tag;
	wire [3:0] r_margin_nib;
	wire [2:0] r_last_engine;
	wire r_irq;
	wire r_disp_sticky;
	wire regs_accept;
	wire r_comp_valid;
	wire [3:0] r_comp_tag;
	hydra_tt_regs #(
		.NTAG(NTAG),
		.HOST_COMP(1'b0)
	) u_regs(
		.clk(clk),
		.rst_n(rst_n),
		.cs_start(cs_start),
		.cs_end(cs_end),
		.rx_valid(rx_valid),
		.rx_byte(rx_byte),
		.rx_index(rx_index),
		.tx_load(tx_load),
		.tx_byte(tx_byte),
		.wd_valid(wd_valid),
		.wd_ready(wd_ready),
		.wd(wd),
		.disp_valid(disp_valid),
		.disp_accept(regs_accept),
		.disp_fire(disp_valid & disp_accept),
		.disp_engine(disp_engine),
		.disp_tag(disp_tag),
		.disp_wd(disp_wd),
		.comp_valid(r_comp_valid),
		.comp_tag(r_comp_tag),
		.fence_tag(r_fence_tag),
		.fence_busy(fence_busy),
		.csr_wr(r_csr_wr),
		.csr_priv(r_csr_priv),
		.csr_engine(r_csr_engine),
		.csr_data(r_csr_data),
		.csr_bw_dma_log2(r_bw),
		.csr_eps_mem(r_eps),
		.csr_e_shift(r_esh),
		.csr_cal_freeze(r_cal_freeze),
		.csr_cal_reset(r_cal_reset),
		.err_unsupported(err_unsupported),
		.err_tag(err_tag),
		.err_stale_comp(err_stale_comp),
		.obs_margin(obs_margin),
		.obs_cal_updates(obs_cal_updates),
		.obs_tag_busy(obs_tag_busy),
		.irq(r_irq),
		.last_engine(r_last_engine),
		.disp_sticky(r_disp_sticky),
		.last_tag(r_last_tag),
		.margin_nib(r_margin_nib)
	);
	wire host_hold = ~regs_accept;
	function automatic [127:0] sv2v_cast_128;
		input reg [127:0] inp;
		sv2v_cast_128 = inp;
	endfunction
	mom_top #(
		.NENG(NENG),
		.NTAG(NTAG),
		.QMAX(4)
	) u_mom(
		.clk(clk),
		.rst_n(rst_n),
		.wd_valid(s_wd_valid),
		.wd_ready(s_wd_ready),
		.wd(sv2v_cast_128(s_wd)),
		.eng_elig(s_elig),
		.disp_valid(disp_valid),
		.disp_accept(disp_accept),
		.disp_engine(disp_engine),
		.disp_tag(disp_tag),
		.disp_wd(disp_wd),
		.comp_valid(comp_valid),
		.comp_tag(comp_tag),
		.fence_tag(r_fence_tag),
		.fence_busy(fence_busy),
		.csr_wr(r_csr_wr),
		.csr_priv(r_csr_priv),
		.csr_engine(r_csr_engine),
		.csr_data(r_csr_data),
		.csr_bw_dma_log2(r_bw),
		.csr_eps_mem(r_eps),
		.csr_e_shift(r_esh),
		.csr_cal_freeze(r_cal_freeze),
		.csr_cal_reset(r_cal_reset),
		.err_unsupported(m_err_unsupported),
		.err_tag(m_err_tag),
		.err_stale_comp(err_stale_comp),
		.obs_margin(obs_margin),
		.obs_cal_updates(obs_cal_updates),
		.obs_tag_busy(obs_tag_busy)
	);
	assign err_unsupported = m_err_unsupported | abi_err;
	assign err_tag = (abi_err ? abi_err_tag : m_err_tag);
	wire cpu_disp_valid;
	wire [127:0] cpu_disp_wd;
	wire [63:0] cpu_disp_hdr;
	wire cpu_disp_taken;
	wire [63:0] cpu_disp_status;
	wire sel_cpu = cpu_disp_valid;
	wire fe_valid = wd_valid || cpu_disp_valid;
	wire fe_ready;
	reg [63:0] hdr_q;
	wire [63:0] fe_hdr = (sel_cpu ? cpu_disp_hdr : hdr_q);
	function automatic [127:0] sv2v_cast_D3020;
		input reg [127:0] inp;
		sv2v_cast_D3020 = inp;
	endfunction
	wire [127:0] fe_body = (sel_cpu ? sv2v_cast_D3020(cpu_disp_wd) : wd);
	assign wd_ready = fe_ready && !sel_cpu;
	assign cpu_disp_taken = fe_ready && sel_cpu;
	reg src_cpu_q;
	reg [7:0] cd_refused;
	reg [7:0] cd_dispatched;
	reg [3:0] cd_code;
	reg [15:0] cd_completed;
	reg [15:0] cd_tags;
	wire fire = disp_valid && disp_accept;
	wire [3:0] abi_code;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			src_cpu_q <= 1'b0;
			cd_refused <= 1'sb0;
			cd_dispatched <= 1'sb0;
			cd_code <= 1'sb0;
			cd_completed <= 1'sb0;
			cd_tags <= 1'sb0;
		end
		else begin
			if (fe_valid && fe_ready)
				src_cpu_q <= sel_cpu;
			if (src_cpu_q && abi_err) begin
				cd_refused <= cd_refused + 8'd1;
				cd_code <= abi_code;
			end
			else if (src_cpu_q && m_err_unsupported) begin
				cd_refused <= cd_refused + 8'd1;
				cd_code <= 4'd7;
			end
			if (src_cpu_q && fire) begin
				cd_dispatched <= cd_dispatched + 8'd1;
				cd_tags[disp_tag] <= 1'b1;
			end
			if (comp_valid && cd_tags[comp_tag]) begin
				cd_completed <= cd_completed + 16'd1;
				cd_tags[comp_tag] <= 1'b0;
			end
		end
	assign cpu_disp_status = {cd_tags, cd_completed, cd_dispatched, 4'd0, cd_code, cd_refused, 8'd0};
	wire ctl_sel = ((mem_we && (mem_bank == 2'd3)) && (mem_addr[15:14] == 2'd3)) && (mem_addr[13:4] == 10'd0);
	reg [NENG - 1:0] healthy_q;
	reg [3:0] abi_last_code;
	reg [15:0] abi_refusals;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			hdr_q <= 1'sb0;
			healthy_q <= 1'sb1;
			abi_last_code <= 1'sb0;
			abi_refusals <= 1'sb0;
		end
		else begin
			if (ctl_sel && (mem_addr[3:0] == 4'd2))
				hdr_q[31:0] <= mem_wdata;
			if (ctl_sel && (mem_addr[3:0] == 4'd3))
				hdr_q[63:32] <= mem_wdata;
			if (ctl_sel && (mem_addr[3:0] == 4'd5))
				healthy_q <= mem_wdata[NENG - 1:0];
			if (abi_err) begin
				abi_last_code <= abi_code;
				abi_refusals <= abi_refusals + 16'd1;
			end
		end
	wire [31:0] abi_status = {abi_refusals, 12'd0, abi_last_code};
	localparam [0:0] REAL_CPU = CPU_ENGINE == 1;
	reg [13:0] cpu_addr_q;
	reg [4:0] cpu_reg_q;
	wire cpu_wr = ctl_sel && (mem_addr[3:0] == 4'd7);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			cpu_addr_q <= 1'sb0;
			cpu_reg_q <= 1'sb0;
		end
		else begin
			if (ctl_sel && (mem_addr[3:0] == 4'd6))
				cpu_addr_q <= mem_wdata[13:0];
			else if (cpu_wr)
				cpu_addr_q <= cpu_addr_q + 14'd1;
			if (ctl_sel && (mem_addr[3:0] == 4'd10))
				cpu_reg_q <= mem_wdata[4:0];
		end
	wire cpu_ready;
	wire cpu_done;
	wire [3:0] cpu_done_tag;
	wire [1:0] cpu_status;
	wire [63:0] cpu_tohost;
	wire [63:0] cpu_dbg;
	wire [31:0] cpu_rdata;
	wire cpu_ld_refused;
	wire [31:0] cpu_perf;
	localparam [0:0] SBOOT = REAL_CPU && (SECURE_BOOT != 0);
	wire sb_busy;
	wire sb_verified;
	wire sb_failed;
	wire sb_lock_load;
	wire sb_lock_debug;
	localparam signed [31:0] SB_AW = $clog2(CPU_MEM_BYTES / 4);
	localparam signed [31:0] SB_MAXW = CPU_MEM_BYTES / 4;
	wire [SB_AW - 1:0] sb_rd_addr;
	wire [255:0] sb_digest;
	wire [255:0] sb_pcr;
	wire [15:0] sb_boots;
	reg [14:0] sb_len_q;
	reg [3:0] sb_sel_q;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			sb_len_q <= 1'sb0;
			sb_sel_q <= 1'sb0;
		end
		else begin
			if (ctl_sel && (mem_addr[3:0] == 4'd11))
				sb_len_q <= mem_wdata[14:0];
			if (ctl_sel && (mem_addr[3:0] == 4'd13))
				sb_sel_q <= mem_wdata[3:0];
		end
	function automatic signed [((SB_AW + 0) >= 0 ? SB_AW + 1 : 1 - (SB_AW + 0)) - 1:0] sv2v_cast_EAE6C_signed;
		input reg signed [((SB_AW + 0) >= 0 ? SB_AW + 1 : 1 - (SB_AW + 0)) - 1:0] inp;
		sv2v_cast_EAE6C_signed = inp;
	endfunction
	generate
		if (SBOOT) begin : g_sboot
			hydra_secure_boot #(
				.GOLDEN(BOOT_GOLDEN),
				.AW(SB_AW)
			) u_sboot(
				.clk(clk),
				.rst_n(rst_n),
				.boot_start(ctl_sel && (mem_addr[3:0] == 4'd12)),
				.boot_len(({17'd0, sb_len_q} > SB_MAXW ? sv2v_cast_EAE6C_signed(0) : sb_len_q[SB_AW:0])),
				.rd_addr(sb_rd_addr),
				.rd_data(cpu_rdata),
				.busy(sb_busy),
				.verified(sb_verified),
				.failed(sb_failed),
				.lock_load(sb_lock_load),
				.lock_debug(sb_lock_debug),
				.digest(sb_digest),
				.pcr(sb_pcr),
				.boots(sb_boots)
			);
		end
		else begin : g_no_sboot
			assign sb_busy = 1'b0;
			assign sb_verified = 1'b0;
			assign sb_failed = 1'b0;
			assign sb_lock_load = 1'b0;
			assign sb_lock_debug = 1'b0;
			assign sb_rd_addr = 1'sb0;
			assign sb_digest = 1'sb0;
			assign sb_pcr = 1'sb0;
			assign sb_boots = 1'sb0;
		end
	endgenerate
	wire [511:0] sb_words = {sb_digest, sb_pcr};
	wire [3:0] sb_idx = 4'd15 - sb_sel_q;
	wire [31:0] sb_word = sb_words[{sb_idx, 5'd0}+:32];
	wire cpu_boot_ok = !SBOOT || sb_verified;
	wire [(NENG * 4) - 1:0] eng_tag;
	wire [NENG - 1:0] eng_valid;
	wire [127:0] eng_wd;
	function automatic [13:0] sv2v_cast_14;
		input reg [13:0] inp;
		sv2v_cast_14 = inp;
	endfunction
	generate
		if (REAL_CPU) begin : g_real_cpu
			wire cpu_uart_idle;
			hydra_engine_cpu #(
				.TAGW(4),
				.CACHED(CPU_CACHED != 0),
				.SRAM(CPU_SRAM != 0),
				.SRAM_MODEL(CPU_SRAM_MODEL != 0),
				.MEM_BYTES(CPU_MEM_BYTES),
				.CACHE_SETS(CPU_CACHE_SETS)
			) u_cpu(
				.clk(clk),
				.rst_n(rst_n),
				.eng_valid(eng_valid[0]),
				.eng_ready(cpu_ready),
				.eng_wd(eng_wd),
				.eng_tag(eng_tag[3:0]),
				.eng_done(cpu_done),
				.eng_done_tag(cpu_done_tag),
				.job_status(cpu_status),
				.tohost(cpu_tohost),
				.disp_valid(cpu_disp_valid),
				.disp_wd(cpu_disp_wd),
				.disp_hdr(cpu_disp_hdr),
				.disp_taken(cpu_disp_taken),
				.disp_status(cpu_disp_status),
				.ld_we(cpu_wr && !sb_lock_load),
				.ld_addr(cpu_addr_q),
				.ld_data(mem_wdata),
				.ld_refused(cpu_ld_refused),
				.rd_addr((sb_busy ? sv2v_cast_14(sb_rd_addr) : cpu_addr_q)),
				.rd_data(cpu_rdata),
				.dbg_reg(cpu_reg_q),
				.dbg_data(cpu_dbg),
				.cfg_we(ctl_sel && (((mem_addr[3:0] == 4'd8) && !sb_lock_load) || (mem_addr[3:0] == 4'd9))),
				.cfg_addr(mem_addr[0]),
				.cfg_data(mem_wdata),
				.perf_cycles(cpu_perf),
				.uart_tx(cpu_uart_tx),
				.uart_idle(cpu_uart_idle),
				.gpio_out(cpu_gpio_out),
				.gpio_in(cpu_gpio_in)
			);
			wire _unused_uart = &{1'b0, cpu_uart_idle};
		end
		else begin : g_no_cpu
			assign cpu_uart_tx = 1'b1;
			assign cpu_gpio_out = 16'd0;
			wire _unused_gpio = &{1'b0, cpu_gpio_in};
			assign cpu_ld_refused = 1'b0;
			assign cpu_perf = 32'd0;
			assign cpu_disp_valid = 1'b0;
			assign cpu_disp_wd = 1'sb0;
			assign cpu_disp_hdr = 1'sb0;
			assign cpu_ready = 1'b0;
			assign cpu_done = 1'b0;
			assign cpu_done_tag = 4'd0;
			assign cpu_status = 2'd0;
			assign cpu_tohost = 1'sb0;
			assign cpu_dbg = 1'sb0;
			assign cpu_rdata = 1'sb0;
		end
	endgenerate
	reg [31:0] ctl_rdata;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (mem_raddr[3:0])
			4'd1: ctl_rdata = (sb_lock_debug ? 32'd0 : cpu_rdata);
			4'd2: ctl_rdata = (sb_lock_debug ? 32'd0 : cpu_dbg[31:0]);
			4'd3: ctl_rdata = (sb_lock_debug ? 32'd0 : cpu_dbg[63:32]);
			4'd4: ctl_rdata = {cpu_status, cpu_tohost[29:0]};
			4'd5: ctl_rdata = {sb_verified, sb_failed, sb_busy, sb_lock_load, 12'd0, sb_boots};
			4'd6: ctl_rdata = sb_word;
			4'd7: ctl_rdata = {18'd0, pins_q};
			default: ctl_rdata = abi_status;
		endcase
	end
	generate
		if (ABI_V2 != 0) begin : g_abi_v2
			hydra_abi_v2 #(
				.NENG(NENG),
				.NCTX(16)
			) u_abi(
				.clk(clk),
				.rst_n(rst_n),
				.in_valid(fe_valid),
				.in_ready(fe_ready),
				.in_hdr(fe_hdr),
				.in_body(fe_body),
				.out_valid(s_wd_valid),
				.out_ready(s_wd_ready),
				.out_body(s_wd),
				.out_elig(s_elig),
				.sched_done((disp_valid && disp_accept) || m_err_unsupported),
				.err_valid(abi_err),
				.err_code(abi_code),
				.err_tag(abi_err_tag),
				.ctx_we(ctl_sel && (mem_addr[3:0] == 4'd4)),
				.ctx_id(mem_wdata[23:16]),
				.ctx_owned(mem_wdata[24]),
				.ctx_epoch(mem_wdata[15:0]),
				.healthy(healthy_q & {{NENG - 1 {1'b1}}, cpu_boot_ok && !sel_cpu})
			);
		end
		else begin : g_abi_v1
			assign s_wd_valid = fe_valid;
			assign fe_ready = s_wd_ready;
			assign s_wd = fe_body;
			assign s_elig = 1'sb1;
			assign abi_err = 1'b0;
			assign abi_code = 4'd0;
			assign abi_err_tag = 8'd0;
		end
	endgenerate
	wire [NENG - 1:0] eng_ready_raw;
	wire [NENG - 1:0] eng_done;
	wire [NENG - 1:0] eng_busy;
	wire [(NENG * 4) - 1:0] eng_done_tag;
	wire err_bad_engine;
	wire err_done_unknown;
	wire [NENG - 1:0] eng_ready = eng_ready_raw & {NENG {~host_hold}};
	mom_xbar #(
		.NENG(NENG),
		.NTAG(NTAG),
		.WD_W(mom_pkg_WD_W),
		.TAGW(4),
		.ENGW(3)
	) u_xbar(
		.clk(clk),
		.rst_n(rst_n),
		.disp_valid(disp_valid),
		.disp_accept(disp_accept),
		.disp_engine(disp_engine),
		.disp_tag(disp_tag),
		.disp_wd(disp_wd),
		.comp_valid(comp_valid),
		.comp_tag(comp_tag),
		.eng_valid(eng_valid),
		.eng_ready(eng_ready),
		.eng_wd(eng_wd),
		.eng_tag(eng_tag),
		.eng_done(eng_done),
		.eng_done_tag(eng_done_tag),
		.eng_busy(eng_busy),
		.err_bad_engine(err_bad_engine),
		.err_done_unknown(err_done_unknown)
	);
	wire _unused_wd = &{eng_wd, r_comp_valid, r_comp_tag, r_irq, r_disp_sticky, 1'b0};
	wire [1:0] prof = ui_in[7:6];
	wire slow_tpu = (prof == 2'b01) || (prof == 2'b11);
	wire slow_simd = (prof == 2'b10) || (prof == 2'b11);
	wire [31:0] tpu_checksum;
	assign dbg_checksum = tpu_checksum;
	wire [15:0] memtpu_tiles;
	wire [15:0] tpu_tiles;
	assign dbg_tiles = (TPU_FROM_MEM ? memtpu_tiles : tpu_tiles);
	wire [31:0] simd_checksum;
	assign dbg_simd_checksum = simd_checksum;
	wire [15:0] simd_jobs;
	assign dbg_simd_jobs = simd_jobs;
	wire tpu_ready;
	wire tpu_done;
	wire [3:0] tpu_done_tag;
	wire memtpu_ready;
	wire memtpu_done;
	wire [3:0] memtpu_done_tag;
	wire [2:0] memtpu_status;
	wire [1:0] tpu_status;
	wire [1:0] simd_status;
	wire [1:0] gpu_status;
	wire [31:0] gpu_perf;
	wire gpu_ready;
	wire gpu_done;
	wire gpu_refused;
	wire [3:0] gpu_done_tag;
	wire [31:0] gpu_rdata;
	wire [31:0] tpu_m_rdata;
	wire tpu_m_refused;
	assign mem_rdata = (mem_raddr[15:14] == 2'd3 ? (mem_raddr[13:4] == 10'd0 ? ctl_rdata : 32'd0) : (REAL_GPU && (mem_raddr[15:14] == 2'd2) ? gpu_rdata : tpu_m_rdata));
	assign mem_refused = tpu_m_refused | gpu_refused;
	generate
		if (TPU_FROM_MEM) begin : g_mem_tpu
			hydra_engine_tpu_dma #(
				.N(4),
				.WD_W(mom_pkg_WD_W),
				.TAGW(4),
				.MAW(10),
				.DEPTH(1024)
			) u_memtpu(
				.clk(clk),
				.rst_n(rst_n),
				.eng_valid(eng_valid[2]),
				.eng_ready(memtpu_ready),
				.eng_wd(eng_wd),
				.eng_tag(eng_tag[8+:4]),
				.eng_done(memtpu_done),
				.eng_done_tag(memtpu_done_tag),
				.ld_we(mem_we && !(REAL_GPU && (mem_bank == 2'd3))),
				.ld_bank(mem_bank),
				.ld_addr(mem_addr[9:0]),
				.ld_data(mem_wdata),
				.ld_refused(tpu_m_refused),
				.c_raddr(mem_raddr[9:0]),
				.c_rdata(tpu_m_rdata),
				.tiles_done(memtpu_tiles),
				.job_status(memtpu_status)
			);
		end
		else begin : g_no_mem_tpu
			assign memtpu_ready = 1'b0;
			assign memtpu_done = 1'b0;
			assign memtpu_done_tag = 4'd0;
			assign memtpu_tiles = 16'd0;
			assign memtpu_status = 3'd0;
			assign tpu_m_rdata = 32'd0;
			assign tpu_m_refused = 1'b0;
		end
		if (REAL_TPU) begin : g_real_tpu
			hydra_engine_tpu #(
				.N(4),
				.WD_W(mom_pkg_WD_W),
				.TAGW(4)
			) u_tpu(
				.clk(clk),
				.rst_n(rst_n),
				.eng_valid(eng_valid[2]),
				.eng_ready(tpu_ready),
				.eng_wd(eng_wd),
				.eng_tag(eng_tag[8+:4]),
				.eng_done(tpu_done),
				.eng_done_tag(tpu_done_tag),
				.checksum(tpu_checksum),
				.tiles_done(tpu_tiles),
				.last_status(tpu_status)
			);
		end
		else begin : g_no_tpu
			assign tpu_ready = 1'b0;
			assign tpu_done = 1'b0;
			assign tpu_done_tag = 4'd0;
			assign tpu_checksum = 32'd0;
			assign tpu_tiles = 16'd0;
			assign tpu_status = 2'd0;
		end
	endgenerate
	wire simd_ready;
	wire simd_done;
	wire [3:0] simd_done_tag;
	generate
		if (REAL_SIMD) begin : g_real_simd
			hydra_engine_simd #(
				.N(4),
				.WD_W(mom_pkg_WD_W),
				.TAGW(4)
			) u_simd(
				.clk(clk),
				.rst_n(rst_n),
				.eng_valid(eng_valid[1]),
				.eng_ready(simd_ready),
				.eng_wd(eng_wd),
				.eng_tag(eng_tag[4+:4]),
				.eng_done(simd_done),
				.eng_done_tag(simd_done_tag),
				.checksum(simd_checksum),
				.jobs_done(simd_jobs),
				.last_status(simd_status)
			);
		end
		else begin : g_no_simd
			assign simd_ready = 1'b0;
			assign simd_done = 1'b0;
			assign simd_done_tag = 4'd0;
			assign simd_checksum = 32'd0;
			assign simd_jobs = 16'd0;
			assign simd_status = 2'd0;
		end
	endgenerate
	wire gpu_sel = mem_bank == 2'd3;
	generate
		if (REAL_GPU) begin : g_real_gpu
			hydra_engine_gpu #(
				.TAGW(4),
				.AW(12)
			) u_gpu(
				.clk(clk),
				.rst_n(rst_n),
				.eng_valid(eng_valid[5]),
				.eng_ready(gpu_ready),
				.eng_wd(eng_wd),
				.eng_tag(eng_tag[20+:4]),
				.eng_done(gpu_done),
				.eng_done_tag(gpu_done_tag),
				.job_status(gpu_status),
				.prog_we((mem_we && gpu_sel) && (mem_addr[15:14] == 2'd1)),
				.prog_addr(mem_addr[9:0]),
				.prog_data(mem_wdata),
				.cons_we((mem_we && gpu_sel) && (mem_addr[15:14] == 2'd2)),
				.cons_addr(mem_addr[3:0]),
				.cons_data(mem_wdata),
				.cfg_we(((mem_we && gpu_sel) && (mem_addr[15:14] == 2'd3)) && (mem_addr[3:1] == 3'd0)),
				.cfg_addr(mem_addr[0]),
				.cfg_data(mem_wdata[15:0]),
				.ld_we((mem_we && gpu_sel) && (mem_addr[15:14] == 2'd0)),
				.ld_addr(mem_addr[11:0]),
				.ld_data(mem_wdata),
				.ld_refused(gpu_refused),
				.rd_addr(mem_raddr[11:0]),
				.rd_data(gpu_rdata),
				.perf_cycles(gpu_perf)
			);
		end
		else begin : g_no_gpu
			assign gpu_ready = 1'b0;
			assign gpu_done = 1'b0;
			assign gpu_done_tag = 4'd0;
			assign gpu_refused = 1'b0;
			assign gpu_rdata = 32'd0;
			assign gpu_status = 2'd0;
			assign gpu_perf = 32'd0;
		end
	endgenerate
	genvar _gv_e_9;
	function automatic [15:0] sv2v_cast_16;
		input reg [15:0] inp;
		sv2v_cast_16 = inp;
	endfunction
	generate
		for (_gv_e_9 = 0; _gv_e_9 < NENG; _gv_e_9 = _gv_e_9 + 1) begin : g_eng
			localparam e = _gv_e_9;
			reg [15:0] cnt;
			reg [3:0] held;
			reg done_q;
			wire [15:0] lat = ((e == 2) && slow_tpu ? sv2v_cast_16(LAT_SLOW) : ((e == 1) && slow_simd ? sv2v_cast_16(LAT_SLOW) : sv2v_cast_16(LAT_FAST + (7 * e))));
			always @(posedge clk or negedge rst_n)
				if (!rst_n) begin
					cnt <= 1'sb0;
					held <= 1'sb0;
					done_q <= 1'b0;
				end
				else begin
					done_q <= 1'b0;
					if (eng_valid[e]) begin
						cnt <= lat;
						held <= eng_tag[e * 4+:4];
					end
					else if (cnt > 16'd1)
						cnt <= cnt - 16'd1;
					else if (cnt == 16'd1) begin
						cnt <= 1'sb0;
						done_q <= 1'b1;
					end
				end
			if (e == 0) begin : g_eng0_sel
				assign eng_ready_raw[e] = (REAL_CPU ? cpu_ready && cpu_boot_ok : cnt == 0);
				assign eng_done[e] = (REAL_CPU ? cpu_done : done_q);
				assign eng_done_tag[e * 4+:4] = (REAL_CPU ? cpu_done_tag : held);
			end
			else if (e == 1) begin : g_eng1_sel
				assign eng_ready_raw[e] = (REAL_SIMD ? simd_ready : cnt == 0);
				assign eng_done[e] = (REAL_SIMD ? simd_done : done_q);
				assign eng_done_tag[e * 4+:4] = (REAL_SIMD ? simd_done_tag : held);
			end
			else if (e == 2) begin : g_eng2_sel
				assign eng_ready_raw[e] = (TPU_FROM_MEM ? memtpu_ready : (REAL_TPU ? tpu_ready : cnt == 0));
				assign eng_done[e] = (TPU_FROM_MEM ? memtpu_done : (REAL_TPU ? tpu_done : done_q));
				assign eng_done_tag[e * 4+:4] = (TPU_FROM_MEM ? memtpu_done_tag : (REAL_TPU ? tpu_done_tag : held));
			end
			else if (e == 5) begin : g_eng5_sel
				assign eng_ready_raw[e] = (REAL_GPU ? gpu_ready : cnt == 0);
				assign eng_done[e] = (REAL_GPU ? gpu_done : done_q);
				assign eng_done_tag[e * 4+:4] = (REAL_GPU ? gpu_done_tag : held);
			end
			else begin : g_eng_model
				assign eng_ready_raw[e] = cnt == 0;
				assign eng_done[e] = done_q;
				assign eng_done_tag[e * 4+:4] = held;
			end
		end
	endgenerate
	assign uo_out = {wd_ready, |eng_busy, r_disp_sticky, r_last_engine, (r_irq | err_bad_engine) | err_done_unknown, cipo};
	assign uio_out = {r_margin_nib[3:1], err_done_unknown, eng_busy[3:0] | {3'b000, eng_busy[4]}};
	assign uio_oe = 8'hff;
	wire _unused_cs = &{cs_active, r_margin_nib[0], r_last_tag, 1'b0};
	wire _unused_eng = &{1'b0, cpu_ld_refused, cpu_perf, cpu_tohost[63:30], memtpu_status, tpu_status, simd_status, gpu_status, gpu_perf, gpu_ready, gpu_done, gpu_done_tag, gpu_sel, TPU_MODEL[0], SIMD_MODEL[0]};
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire
`default_nettype none
module hydra_mcu_core (
	clk,
	rst_n,
	ui_in,
	uo_out,
	uio_in,
	uio_out,
	uio_oe,
	mem_we,
	mem_bank,
	mem_addr,
	mem_wdata,
	mem_raddr,
	mem_rdata,
	mem_refused,
	cpu_uart_tx,
	cpu_gpio_out,
	cpu_gpio_in
);
	parameter [255:0] BOOT_GOLDEN = 256'h0000000000000000000000000000000000000000000000000000000000000000;
	input wire clk;
	input wire rst_n;
	input wire [7:0] ui_in;
	output wire [7:0] uo_out;
	input wire [7:0] uio_in;
	output wire [7:0] uio_out;
	output wire [7:0] uio_oe;
	input wire mem_we;
	input wire [1:0] mem_bank;
	input wire [15:0] mem_addr;
	input wire [31:0] mem_wdata;
	input wire [15:0] mem_raddr;
	output wire [31:0] mem_rdata;
	output wire mem_refused;
	output wire cpu_uart_tx;
	output wire [15:0] cpu_gpio_out;
	input wire [15:0] cpu_gpio_in;
	wire [31:0] dbg_ck;
	wire [31:0] dbg_sck;
	wire [15:0] dbg_t;
	wire [15:0] dbg_sj;
	hydra_sys_tile #(
		.NENG(5),
		.TPU_ENGINE(1),
		.SIMD_ENGINE(1),
		.ABI_V2(1),
		.CPU_ENGINE(1),
		.SECURE_BOOT(1),
		.BOOT_GOLDEN(BOOT_GOLDEN),
		.CPU_CACHED(1),
		.CPU_SRAM(1),
		.CPU_SRAM_MODEL(0),
		.CPU_MEM_BYTES(16384),
		.CPU_CACHE_SETS(16)
	) u_sys(
		.ui_in(ui_in),
		.uo_out(uo_out),
		.uio_in(uio_in),
		.uio_out(uio_out),
		.uio_oe(uio_oe),
		.ena(1'b1),
		.clk(clk),
		.rst_n(rst_n),
		.dbg_checksum(dbg_ck),
		.dbg_tiles(dbg_t),
		.dbg_simd_checksum(dbg_sck),
		.dbg_simd_jobs(dbg_sj),
		.mem_we(mem_we),
		.mem_bank(mem_bank),
		.mem_addr(mem_addr),
		.mem_wdata(mem_wdata),
		.mem_raddr(mem_raddr),
		.mem_rdata(mem_rdata),
		.mem_refused(mem_refused),
		.cpu_uart_tx(cpu_uart_tx),
		.cpu_gpio_out(cpu_gpio_out),
		.cpu_gpio_in(cpu_gpio_in)
	);
	wire _unused = &{1'b0, dbg_ck, dbg_t, dbg_sck, dbg_sj};
endmodule
`default_nettype wire
