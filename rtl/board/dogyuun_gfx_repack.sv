// Place each GP9001 lower/upper plane-word pair in one 32-bit SDRAM block.
// The logical renderer address remains identical to MAME's region layout:
// word w of a region of 2^n words is stored at {w[n-2:0], w[n-1]}, n from
// the region's size in the image header (0: 2 MB, n = 20; 1: 4 MB, n = 21;
// 2: 8 MB, n = 22).
module dogyuun_gfx_repack (
    input      [1:0]  size,
    input      [21:0] logical_addr,
    output reg [21:0] physical_addr
);

always @(*) begin
    case (size)
        2'd0:    physical_addr = {2'b00, logical_addr[18:0], logical_addr[19]};
        2'd1:    physical_addr = {1'b0,  logical_addr[19:0], logical_addr[20]};
        default: physical_addr = {       logical_addr[20:0], logical_addr[21]};
    endcase
end

endmodule
