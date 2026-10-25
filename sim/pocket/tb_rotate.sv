// Screen Rotation: pocket_rotate's scaler slot through pocket_video's
// end-of-line word, and its turned D-pad, for every game kind (ROT270,
// ROT0), every setting (3 is not offered and must act as 0) and both kinds
// of player-1 controller (the Pocket's own, a Dock's).
//
// The D-pad is checked against a model of the Pocket in the hand, not
// against pocket_rotate's table: each of the Pocket's four directions points
// a way in the room for the way the Pocket is held, and with the picture
// upright in the room the game's direction is the room's. video.json's
// scaler modes are 0 turned 270, 1 as it is, 2 turned 180.
//
//   make rotate
`timescale 1ns/1ps

module tb_rotate;
    // 94.5 MHz and 6.75 MHz, one in fourteen, edges together as the PLL has
    // them
    reg clk = 1'b0, clk_vid = 1'b0;
    always #(1000.0/189.0) clk = ~clk;
    always #(1000.0/13.5)  clk_vid = ~clk_vid;

    reg [3:0] cen_cnt = 4'd0;
    wire      ce_pix  = (cen_cnt == 4'd0);
    always @(posedge clk) cen_cnt <= (cen_cnt == 4'd13) ? 4'd0 : cen_cnt + 4'd1;

    // a short line: 32 pixels shown, 16 blanked, hsync in the blanking
    reg [5:0] hcnt = 6'd0;
    always @(posedge clk) if (ce_pix) hcnt <= (hcnt == 6'd47) ? 6'd0 : hcnt + 6'd1;
    wire hblank = (hcnt >= 6'd32);
    wire hs     = (hcnt >= 6'd38 && hcnt < 6'd42);

    reg  [1:0] rot;
    reg        rot0, pocket_pad;
    reg  [3:0] dpad;
    wire [2:0] slot;
    wire [3:0] dpad_game;

    pocket_rotate dut (
        .rot (rot), .rot0 (rot0), .pocket_pad (pocket_pad), .dpad (dpad),
        .scaler_slot (slot), .dpad_game (dpad_game)
    );

    wire [23:0] video_rgb;
    wire        video_de, video_hs, video_vs, video_skip;
    pocket_video u_video (
        .clk (clk), .ce_pix (ce_pix),
        .hs (hs), .vs (1'b0), .hblank (hblank), .vblank (1'b0),
        .r (8'h55), .g (8'h66), .b (8'h77),
        .scaler_slot (slot),
        .clk_vid (clk_vid),
        .video_rgb (video_rgb), .video_de (video_de),
        .video_hs (video_hs), .video_vs (video_vs), .video_skip (video_skip)
    );

    // the first cycle after DE falls
    reg        de_q = 1'b0;
    reg [23:0] eol_word = 24'hffffff;
    integer    eol_seen = 0;
    always @(posedge clk_vid) begin
        de_q <= video_de;
        if (de_q && !video_de) begin
            eol_word <= video_rgb;
            eol_seen <= eol_seen + 1;
        end
    end

    // The room's direction each of the Pocket's buttons points, held
    // upright (0), turned a quarter anticlockwise (1) or clockwise (2).
    // Directions as APF's bits: 0 up, 1 down, 2 left, 3 right.
    function automatic [1:0] points(input [1:0] held, input [1:0] button);
        case (held)
        2'd1:    case (button)                      // anticlockwise
                 2'd0: points = 2'd2;               //   up    -> left
                 2'd1: points = 2'd3;               //   down  -> right
                 2'd2: points = 2'd1;               //   left  -> down
                 default: points = 2'd0;            //   right -> up
                 endcase
        2'd2:    case (button)                      // clockwise
                 2'd0: points = 2'd3;               //   up    -> right
                 2'd1: points = 2'd2;               //   down  -> left
                 2'd2: points = 2'd0;               //   left  -> up
                 default: points = 2'd1;            //   right -> down
                 endcase
        default: points = button;
        endcase
    endfunction

    function automatic [3:0] in_room(input [1:0] held, input [3:0] d);
        integer b;
        in_room = 4'd0;
        for (b = 0; b < 4; b = b + 1)
            if (d[b]) in_room[points(held, b[1:0])] = 1'b1;
    endfunction

    integer errors = 0, checks = 0;
    integer r, k, p, d, n0;
    reg [2:0] want_slot;
    reg [1:0] held;
    reg [3:0] want_dpad;

    initial begin
        rot = 2'd0; rot0 = 1'b0; pocket_pad = 1'b1; dpad = 4'd0;
        for (k = 0; k < 2; k = k + 1)
        for (r = 0; r < 4; r = r + 1)
        for (p = 0; p < 2; p = p + 1) begin
            rot0 = k[0]; rot = r[1:0]; pocket_pad = p[0];
            // Knuckle Bash: as it is, whatever the setting. The vertical
            // games: 0 Upright (turned 270), 1 Tate (left) as it is, 2 Tate
            // (right) turned 180; 3 as 0.
            want_slot = rot0 ? 3'd1 : (r == 1) ? 3'd1 : (r == 2) ? 3'd2 : 3'd0;
            // The Pocket is held on its side in Tate on a vertical game; a
            // Dock's controller is not, nor is anything on Knuckle Bash.
            held = (!rot0 && pocket_pad && (r == 1 || r == 2)) ? r[1:0] : 2'd0;

            // two lines, then the word of the third
            n0 = eol_seen;
            wait (eol_seen >= n0 + 3);
            @(negedge clk_vid);
            checks = checks + 1;
            if (eol_word[23:13] != {8'd0, want_slot} || eol_word[12:0] != 13'd0) begin
                errors = errors + 1;
                $display("FAIL slot: rot0=%0d rot=%0d pad=%0d word %06h, want slot %0d",
                         rot0, r, p, eol_word, want_slot);
            end

            for (d = 0; d < 16; d = d + 1) begin
                dpad = d[3:0];
                #1;
                want_dpad = in_room(held, dpad);
                checks = checks + 1;
                if (dpad_game !== want_dpad) begin
                    errors = errors + 1;
                    $display("FAIL dpad: rot0=%0d rot=%0d pad=%0d in %b out %b, want %b",
                             rot0, r, p, dpad, dpad_game, want_dpad);
                end
            end
            $display("rot0=%0d rot=%0d pocket_pad=%0d: slot %0d, the game's up is the Pocket's %s",
                     rot0, r, p, slot,
                     (held == 2'd1) ? "right" : (held == 2'd2) ? "left" : "up");
        end
        if (errors == 0) $display("rotate: %0d checks, all pass", checks);
        else             $display("rotate: %0d of %0d checks FAIL", errors, checks);
        $finish;
    end
endmodule
