// -----------------------------------------------------------------------------
// gpu_pkg.sv
// Tiny "GPU" command set and constants for the Tetris demo engine.
//
// This is NOT a full 3D GPU. It's a small, FPGA-friendly 2D tile renderer that
// draws a 10x20 Tetris board into a VGA-like pixel stream.
//
// The command stream can be plaintext or "SIEEECURE-style" encrypted:
//   entry[127:64] = ctr
//   entry[63:0]   = payload (plaintext) OR enc_payload (ciphertext)
//
// When encrypted, payload is recovered using:
//   ks = AES_encrypt({seed, ctr});
//   payload = enc_payload XOR ks[63:0];
// -----------------------------------------------------------------------------
package gpu_pkg;
    // Command payload encoding (64-bit)
    //   [63:56] opcode
    //   [55:52] value (tile id / color)
    //   [51:48] x (0..15)
    //   [47:43] y (0..31)
    //   [15:0]  misc (WAIT frames)
    localparam logic [7:0] GPUCMD_NOP        = 8'h00;
    localparam logic [7:0] GPUCMD_CLEAR      = 8'h01;
    localparam logic [7:0] GPUCMD_SET_CELL   = 8'h02;
    localparam logic [7:0] GPUCMD_WAIT       = 8'h03;
    localparam logic [7:0] GPUCMD_END        = 8'hFF;

    // Board geometry
    localparam int BOARD_W = 10;
    localparam int BOARD_H = 20;

    // Simple 8-bit RGB palette (RGB332-ish mapping).
    // The renderer maps tile values (0..15) to 8-bit per-channel outputs.
    function automatic [23:0] tile_to_rgb(input logic [3:0] t);
        logic [7:0] r,g,b;
        begin
            unique case (t)
                4'd0: begin r=8'h00; g=8'h00; b=8'h00; end // empty
                4'd1: begin r=8'h00; g=8'hFF; b=8'hFF; end // I (cyan)
                4'd2: begin r=8'h00; g=8'h00; b=8'hFF; end // J (blue)
                4'd3: begin r=8'hFF; g=8'hA5; b=8'h00; end // L (orange)
                4'd4: begin r=8'hFF; g=8'hFF; b=8'h00; end // O (yellow)
                4'd5: begin r=8'h00; g=8'hFF; b=8'h00; end // S (green)
                4'd6: begin r=8'h80; g=8'h00; b=8'h80; end // T (purple)
                4'd7: begin r=8'hFF; g=8'h00; b=8'h00; end // Z (red)
                4'd8: begin r=8'h40; g=8'h40; b=8'h40; end // floor/gray
                default: begin r=8'h20; g=8'h20; b=8'h20; end
            endcase
            tile_to_rgb = {r,g,b};
        end
    endfunction
endpackage
