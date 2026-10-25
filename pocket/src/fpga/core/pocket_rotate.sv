// SPDX-License-Identifier: GPL-3.0-or-later
// Toaplan V2 for Analogue Pocket — Screen Rotation: the scaler slot and the
// D-pad
//
// The vertical games (MAME's ROT270 sets) stand upright on the Pocket held
// as it is, through video.json's scaler mode 0, turned 270. Screen Rotation
// (interact.json, 0xF1000018) shows them full size on the Pocket held on its
// side instead:
//
//   0 Upright       slot 0, turned 270, the D-pad as it is
//   1 Tate (left)   slot 1, the board's picture as it is; the Pocket turned
//                   a quarter anticlockwise, so its right is the game's up
//   2 Tate (right)  slot 2, the same turned 180; the Pocket turned a quarter
//                   clockwise, so its left is the game's up
//
// The horizontal game (Knuckle Bash, ROT0) is always slot 1 and its D-pad is
// never turned. Only the Pocket's own controls turn (cont1_key[31:28] type
// 1): a Dock's controller is not turned with the screen, since in Tate the
// TV is the one on its side, as an arcade monitor is. Player 2 and the
// Dock's player 3 never turn.
//
// The D-pad is APF's key[3:0], {right, left, down, up}. Combinational; the
// caller brings every input into its own clock first.

`default_nettype none

module pocket_rotate (
    input  wire [1:0] rot,          // the setting; 3 is taken as 0
    input  wire       rot0,         // the game is horizontal (ROT0)
    input  wire       pocket_pad,   // player 1 is the Pocket's own controls
    input  wire [3:0] dpad,         // player 1's D-pad, {right, left, down, up}
    output wire [2:0] scaler_slot,  // video.json's scaler mode
    output reg  [3:0] dpad_game     // the same in the game's directions
);
    wire [1:0] rot_v = rot0 ? 2'd0 : rot;

    assign scaler_slot = rot0         ? 3'd1 :
                         rot_v == 2'd1 ? 3'd1 :
                         rot_v == 2'd2 ? 3'd2 : 3'd0;

    always @* begin
        case (pocket_pad ? rot_v : 2'd0)
        2'd1:    dpad_game = {dpad[1], dpad[0], dpad[2], dpad[3]};  // Tate (left)
        2'd2:    dpad_game = {dpad[0], dpad[1], dpad[3], dpad[2]};  // Tate (right)
        default: dpad_game = dpad;
        endcase
    end
endmodule

`default_nettype wire
