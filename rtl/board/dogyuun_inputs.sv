// Convert JTFrame's active-low controls to the active-high TP-030 input words.
// TP-026 (FixEight, tp026) has a third player: IN3 is player 3's stick and
// two buttons with START3 in bit 6, SYS bit 0 is COIN3, and button 3 (MAME's
// "Suicide (Cheat)" in bit 6 of IN1/IN2) is left off.
module dogyuun_inputs (
    input             tp026,
    input      [6:0]  joy1_n,
    input      [6:0]  joy2_n,
    input      [6:0]  joy3_n,
    input      [3:0]  start_n,
    input      [3:0]  coin_n,
    input             service_n,
    input             tilt_n,
    input             test_n,
    output     [15:0] in1,
    output     [15:0] in2,
    output     [15:0] in3,
    output     [15:0] sys
);

function automatic [7:0] player_port;
    input [6:0] joy_n;
    input       b3;
    begin
        // MAME/Toaplan: U,D,L,R,B1,B2,B3,unknown.
        player_port = {1'b0,
                       b3 & ~joy_n[6], ~joy_n[5], ~joy_n[4],
                       ~joy_n[0], ~joy_n[1], ~joy_n[2], ~joy_n[3]};
    end
endfunction

assign in1 = {8'h00, player_port(joy1_n, !tp026)};
assign in2 = {8'h00, player_port(joy2_n, !tp026)};
wire [7:0] p3 = player_port(joy3_n, 1'b0);
assign in3 = tp026 ? {8'h00, 1'b0, ~start_n[2], p3[5:0]} : 16'h0000;
assign sys = {8'h00,
              1'b0,
              ~start_n[1], ~start_n[0],
              ~coin_n[1], ~coin_n[0],
              ~test_n, ~tilt_n,
              tp026 ? ~coin_n[2] : ~service_n};

endmodule
