// SPDX-License-Identifier: GPL-3.0-or-later
// Toaplan V2 (Pocket) - TP-026 FixEight's text layer: Toaplan's text
// tilemap (MAME's toaplan_txtilemap, 0.289), drawn over the GP9001.
//
// One 64 x 32 map of 8 x 8 tiles (512 x 256 pixels). A VRAM word is
// {colour[5:0], tile[9:0]}; a pixel's pen is a palette index 0x400 +
// colour x 16 + pen, pen 0 transparent. Each screen line y takes its map row
// from the line select word (src_y = select[y] & 0xff: MAME's scrolly of
// select[y] - y) and its horizontal scroll from the line scroll word of
// that MAP row (MAME's 256 row scrolls index the tilemap's rows), so
// src_x = x - 0x1d5 + scroll[src_y] (MAME's set_offset dx 0x1d5), mod 512.
// MAME also flips the whole layer in x when bit 15 of select[0] is clear;
// FixEight writes 9000 + y to every line (bit 15 set), so the flip is not
// built.
//
// Tile graphics are the 68000's RAM at 600000 (dogyuun_main's u_txgfx, the
// low byte of each word): tile t's row r is bytes 32t + 4r + 0..3, pixels
// 2k and 2k+1 in byte k's high and low nibble.
//
// As the GP9001's state (dogyuun_gp9001_snapshot), the map and the line
// tables are copied at the start of vblank and the next frame is drawn from
// the copy, so a picture is the state MAME draws it from. The graphics are
// not copied (32 KB: 32 more M10K). FixEight loads them whole at boot and on
// leaving its test menu, and in attract rewrites a row or two of tile 0 a
// frame, the blue grid that fills the screen, from its vblank interrupt at
// line 230: read live, the lines drawn after the write showed next frame's
// row (seen on line 233). So the graphics writes made since the copy are
// logged with the byte each overwrote, up to eight, and the renderer reads
// through the log: the frame is drawn from the graphics as they stood at
// the copy. A whole-font load overflows the log and is seen as it lands.
//
// Each line is drawn two lines ahead into one half of a ping-pong buffer
// while the other half is scanned out at display_x; pixel is {colour, pen}
// two clocks after display_x.
module toaplan_text_layer (
    input             clk,
    input             rst,
    input             enable,
    input             snapshot_start,

    output reg [11:0] src_vram_addr,
    input      [15:0] src_vram_data,
    output reg [8:0]  src_line_addr,
    input      [15:0] src_line_data,
    output reg [14:0] gfx_addr,
    input      [7:0]  gfx_data,
    input             gfx_wr,
    input      [14:0] gfx_wr_addr,
    input      [7:0]  gfx_wr_old,

    input             line_event,     // the last pixel of line vcnt
    input      [8:0]  vcnt,
    input      [8:0]  display_x,
    output reg [9:0]  pixel
);

localparam [8:0] V_TOTAL = 9'd262;
localparam [8:0] DX = 9'h1d5;

// ------------------------------------------------------------- snapshot
reg        copy_active = 1'b0;
reg        copy_valid = 1'b0;
reg [11:0] copy_wr = 12'd0;
wire       copy_line = copy_wr < 12'd512;

reg  [10:0] snap_vram_rd;
wire [15:0] snap_vram_q;
reg  [8:0]  snap_line_rd;
wire [15:0] snap_line_q;

jtframe_dual_ram16 #(.AW(11)) u_snap_vram (
    .clk0  (clk),
    .data0 (src_vram_data),
    .addr0 (copy_wr[10:0]),
    .we0   ({2{copy_active && copy_valid}}),
    .q0    (),
    .clk1  (clk),
    .data1 (16'h0000),
    .addr1 (snap_vram_rd),
    .we1   (2'b00),
    .q1    (snap_vram_q)
);

jtframe_dual_ram16 #(.AW(9)) u_snap_line (
    .clk0  (clk),
    .data0 (src_line_data),
    .addr0 (copy_wr[8:0]),
    .we0   ({2{copy_active && copy_valid && copy_line}}),
    .q0    (),
    .clk1  (clk),
    .data1 (16'h0000),
    .addr1 (snap_line_rd),
    .we1   (2'b00),
    .q1    (snap_line_q)
);

// The source RAMs answer the clock after their address: copy_wr trails
// the read address by one.
always @(posedge clk) begin
    if (rst) begin
        copy_active <= 1'b0;
        copy_valid <= 1'b0;
        src_vram_addr <= 12'd0;
        src_line_addr <= 9'd0;
        copy_wr <= 12'd0;
    end else if (snapshot_start && enable) begin
        copy_active <= 1'b1;
        copy_valid <= 1'b0;
        src_vram_addr <= 12'd0;
        src_line_addr <= 9'd0;
    end else if (copy_active) begin
        copy_valid <= 1'b1;
        copy_wr <= src_vram_addr;
        if (copy_valid && copy_wr == 12'd2047) begin
            copy_active <= 1'b0;
            copy_valid <= 1'b0;
        end else if (src_vram_addr != 12'd2047) begin
            src_vram_addr <= src_vram_addr + 12'd1;
            src_line_addr <= src_vram_addr[8:0] + 9'd1;
        end
    end
end

// ------------------------------------------------------- graphics undo log
localparam integer LOG = 8;
reg [LOG-1:0] log_valid = {LOG{1'b0}};
reg [14:0]    log_addr [0:LOG-1];
reg [7:0]     log_old  [0:LOG-1];
reg [LOG-1:0] log_wr_hit;
reg [LOG-1:0] log_free;
integer li;
always @(*) begin
    for (li = 0; li < LOG; li = li + 1) begin
        log_wr_hit[li] = log_valid[li] && log_addr[li] == gfx_wr_addr;
        // the first free entry, one-hot: the entries fill from 0 up
        log_free[li] = !log_valid[li] && (li == 0 || log_valid[li == 0 ? 0 : li - 1]);
    end
end
always @(posedge clk) begin
    if (rst || snapshot_start)
        log_valid <= {LOG{1'b0}};
    else if (gfx_wr && enable && log_wr_hit == {LOG{1'b0}}) begin
        for (li = 0; li < LOG; li = li + 1)
            if (log_free[li]) begin
                log_valid[li] <= 1'b1;
                log_addr[li]  <= gfx_wr_addr;
                log_old[li]   <= gfx_wr_old;
            end
    end
end

// The renderer's byte: the logged one if its address was written.
reg       rd_hit = 1'b0;
reg [7:0] rd_old = 8'd0;
always @(posedge clk) begin
    rd_hit <= 1'b0;
    for (li = 0; li < LOG; li = li + 1)
        if (log_valid[li] && log_addr[li] == gfx_addr) begin
            rd_hit <= 1'b1;
            rd_old <= log_old[li];
        end
end
wire [7:0] gfx_byte = rd_hit ? rd_old : gfx_data;

// ------------------------------------------------------------- renderer
localparam [3:0] R_IDLE = 4'd0,
                 R_SEL0 = 4'd1, R_SEL1 = 4'd2,
                 R_SCR0 = 4'd3, R_SCR1 = 4'd4,
                 R_TILE0 = 4'd5, R_TILE1 = 4'd6, R_TILE2 = 4'd7,
                 R_GFX0 = 4'd8, R_GFX1 = 4'd9, R_PIX = 4'd10;

reg [3:0]  rstate = R_IDLE;
reg [8:0]  ty = 9'd0;         // the screen line being drawn
reg [7:0]  src_y = 8'd0;
reg [8:0]  sx = 9'd0;
reg [8:0]  x = 9'd0;
reg [5:0]  colour = 6'd0;
reg [9:0]  code = 10'd0;
reg        lb_we = 1'b0;
reg [9:0]  lb_wr_addr = 10'd0;
reg [9:0]  lb_wr_data = 10'd0;
wire [9:0] lb_q;

wire [8:0] target = (vcnt >= V_TOTAL - 9'd2) ? vcnt + 9'd2 - V_TOTAL : vcnt + 9'd2;

always @(posedge clk) begin
    lb_we <= 1'b0;
    if (rst) begin
        rstate <= R_IDLE;
    end else begin
        case (rstate)
            R_IDLE:
                if (line_event && enable && target < 9'd240) begin
                    ty <= target;
                    snap_line_rd <= {1'b0, target[7:0]};
                    rstate <= R_SEL0;
                end
            R_SEL0: rstate <= R_SEL1;
            R_SEL1: begin
                src_y <= snap_line_q[7:0];
                snap_line_rd <= {1'b1, snap_line_q[7:0]};
                rstate <= R_SCR0;
            end
            R_SCR0: rstate <= R_SCR1;
            R_SCR1: begin
                sx <= snap_line_q[8:0] - DX;
                x <= 9'd0;
                rstate <= R_TILE0;
            end
            R_TILE0: begin
                snap_vram_rd <= {src_y[7:3], sx[8:3]};
                rstate <= R_TILE1;
            end
            R_TILE1: rstate <= R_TILE2;
            R_TILE2: begin
                code <= snap_vram_q[9:0];
                colour <= snap_vram_q[15:10];
                rstate <= R_GFX0;
            end
            R_GFX0: begin
                gfx_addr <= {code, src_y[2:0], sx[2:1]};
                rstate <= R_GFX1;
            end
            R_GFX1: rstate <= R_PIX;
            R_PIX: begin
                lb_we <= 1'b1;
                lb_wr_addr <= {ty[0], x};
                lb_wr_data <= {colour, sx[0] ? gfx_byte[3:0] : gfx_byte[7:4]};
                x <= x + 9'd1;
                sx <= sx + 9'd1;
                if (x == 9'd319)
                    rstate <= R_IDLE;
                else if (sx[2:0] == 3'd7)
                    rstate <= R_TILE0;
                else
                    rstate <= R_GFX0;
            end
            default: rstate <= R_IDLE;
        endcase
    end
end

jtframe_dual_ram #(.DW(10), .AW(10)) u_line_buf (
    .clk0  (clk),
    .data0 (lb_wr_data),
    .addr0 (lb_wr_addr),
    .we0   (lb_we),
    .q0    (),
    .clk1  (clk),
    .data1 (10'd0),
    .addr1 ({vcnt[0], display_x}),
    .we1   (1'b0),
    .q1    (lb_q)
);

always @(posedge clk)
    pixel <= enable ? lb_q : 10'd0;

endmodule
