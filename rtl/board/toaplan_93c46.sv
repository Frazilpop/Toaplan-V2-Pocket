// SPDX-License-Identifier: GPL-3.0-or-later
// Toaplan V2 (Pocket) - TP-026 FixEight's 93C46 serial EEPROM, 64 x 16, on
// the V25's port 0 (CS bit 4, CLK bit 5, DI bit 6 out; DO bit 7 in).
//
// The state machine is MAME's eeprom_serial_93cxx_device (eepromser.cpp,
// 0.289) as the board's V25 sees it, so the V25's reads of DO match MAME's:
//
//   * One port 0 write can move CS, CLK and DI together. MAME's ioport
//     calls the three lines in bit order, so CS's edge is taken first, then
//     CLK's with DI as it was before the write, then DI. A CLK rise in the
//     same write as CS's rise is not a start bit (MAME: machine time must
//     have moved on since CS rose).
//   * A start bit, two opcode bits and six address bits. READ answers a 0
//     (the dummy bit) at once, the word's bit 15 at the next CLK rise, then
//     the rest, then 1s (no streaming). WRITE takes 16 data bits.
//   * Locked from power-on until EWEN; ERASE and ERAL write FFFF, WRAL ANDs
//     its word into every cell (MAME's write_all), all refused while locked.
//   * After a write or erase the chip is busy for MAME's times (WRITE
//     1.75 ms, ERASE 1 ms, WRAL / ERAL 8 ms): a start bit waits for it, and
//     DO shows ready while CS is high between commands. 94.5 MHz clocks.
//   * DO is 1 when nothing drives it.
//
// The 64 words are one dual-port block RAM. Port A is the state machine's.
// Port B belongs to the platform, with the board held in reset: the image's
// EEPROM region streams past the loader first (seed_*: bytes, the set's
// .nv as MAME's zip has it, big-endian words), then a save file, if there is
// one, comes in through the nv_* port as 16-bit words; pocket_nvram reads
// the words back out through nv_* at shutdown. The store holds the chip's
// words as they are, so through pocket_nvram (word w = file bytes 2w, 2w+1,
// low byte first) the .sav is byte for byte MAME's own nvram file for the
// set, which is the zip's .nv with each pair of bytes swapped.
module toaplan_93c46 (
    input             clk,
    input             rst,

    input             cs,
    input             sk,
    input             di,
    output            dout,

    input             seed_we,
    input      [6:0]  seed_addr,
    input      [7:0]  seed_data,

    input      [5:0]  nv_addr,
    input      [15:0] nv_din,
    input             nv_we,
    output     [15:0] nv_dout,
    output reg        nv_dirty,
    input             nv_dirty_clr
);

localparam [2:0] S_RESET   = 3'd0,   // IN_RESET
                 S_START   = 3'd1,   // WAIT_FOR_START_BIT
                 S_COMMAND = 3'd2,   // WAIT_FOR_COMMAND
                 S_READ    = 3'd3,   // READING_DATA
                 S_DATA    = 3'd4,   // WAIT_FOR_DATA
                 S_DONE    = 3'd5;   // WAIT_FOR_COMPLETION

localparam [19:0] T_WRITE = 20'd165375,   // 1750 us
                  T_ERASE = 20'd94500,    // 1000 us
                  T_ALL   = 20'd756000;   // 8000 us

reg  [2:0]  state = S_RESET;
reg         cs_q = 1'b0, sk_q = 1'b0, di_q = 1'b0;
reg         locked = 1'b1;
reg  [3:0]  bits = 4'd0;
reg  [7:0]  cmd = 8'd0;          // opcode and address, as clocked in
reg  [5:0]  addr = 6'd0;
reg  [15:0] shift = 16'd0;       // READ: out of bit 15; WRITE: in at bit 0
reg         read_first = 1'b0;   // READ: the next CLK rise loads the word
reg  [19:0] busy = 20'd0;
wire        ready = busy == 20'd0;

// Port A: a READ fetches its word when the command is complete (it is
// wanted at the next CLK rise, a V25 port write later); WRITE, ERASE and
// the whole-chip commands write through here, ERAL / WRAL one cell a
// clock (WRAL reads each first).
reg  [5:0]  a_addr = 6'd0;
reg  [15:0] a_din = 16'd0;
reg         a_we = 1'b0;
wire [15:0] a_q;
reg  [15:0] read_word = 16'd0;
reg  [1:0]  read_pend = 2'd0;    // a_addr set, then a_q is the word
reg  [1:0]  all_op = 2'd0;       // 0 none, 1 ERAL, 2 WRAL
reg  [1:0]  all_ph = 2'd0;       // WRAL: address, wait, write
reg  [15:0] all_data = 16'd0;
reg  [5:0]  all_i = 6'd0;

wire        b_seed = seed_we;
wire [5:0]  b_addr = b_seed ? seed_addr[6:1] : nv_addr;
wire [15:0] b_din  = b_seed ? {seed_data, seed_data} : nv_din;
wire [1:0]  b_we   = b_seed ? (seed_addr[0] ? 2'b01 : 2'b10) :
                     (nv_we ? 2'b11 : 2'b00);

jtframe_dual_ram16 #(.AW(6)) u_store (
    .clk0  (clk),
    .data0 (a_din),
    .addr0 (a_addr),
    .we0   ({2{a_we}}),
    .q0    (a_q),
    .clk1  (clk),
    .data1 (b_din),
    .addr1 (b_addr),
    .we1   (b_we),
    .q1    (nv_dout)
);

assign dout = (state == S_START) ? ready :
              (state == S_READ)  ? shift[15] : 1'b1;

// The events of one port write, in MAME's order: CS, then CLK with the old
// DI, then DI.
wire cs_rise = cs && !cs_q;
wire cs_fall = !cs && cs_q;
wire sk_rise = sk && !sk_q;

// The state after CS's edge, before CLK's.
reg [2:0] st_cs;
always @(*) begin
    st_cs = state;
    if (cs_rise && state == S_RESET)
        st_cs = S_START;
    else if (cs_fall)
        st_cs = S_RESET;
end

always @(posedge clk) begin
    if (rst) begin
        state <= S_RESET;
        cs_q <= 1'b0;
        sk_q <= 1'b0;
        di_q <= 1'b0;
        locked <= 1'b1;
        bits <= 4'd0;
        shift <= 16'd0;
        read_first <= 1'b0;
        busy <= 20'd0;
        a_we <= 1'b0;
        read_pend <= 2'd0;
        all_op <= 2'd0;
        all_ph <= 2'd0;
        nv_dirty <= 1'b0;
    end else begin
        cs_q <= cs;
        sk_q <= sk;
        di_q <= di;
        a_we <= 1'b0;
        if (busy != 20'd0)
            busy <= busy - 20'd1;
        if (nv_dirty_clr)
            nv_dirty <= 1'b0;

        read_pend <= {read_pend[0], 1'b0};
        if (read_pend[1])
            read_word <= a_q;

        // ERAL: FFFF into a cell a clock. WRAL: each cell read, then written
        // ANDed with the word (a_q is the cell two clocks after its address).
        if (all_op == 2'd1) begin
            a_addr <= all_i;
            a_din <= 16'hffff;
            a_we <= 1'b1;
            nv_dirty <= 1'b1;
            all_i <= all_i + 6'd1;
            if (all_i == 6'd63)
                all_op <= 2'd0;
        end else if (all_op == 2'd2) begin
            all_ph <= (all_ph == 2'd2) ? 2'd0 : all_ph + 2'd1;
            if (all_ph == 2'd0)
                a_addr <= all_i;
            if (all_ph == 2'd2) begin
                a_din <= a_q & all_data;
                a_we <= 1'b1;
                nv_dirty <= 1'b1;
                all_i <= all_i + 6'd1;
                if (all_i == 6'd63)
                    all_op <= 2'd0;
            end
        end

        state <= st_cs;
        if (sk_rise) begin
            case (st_cs)
                S_START:
                    if (di_q && ready && !cs_rise) begin
                        bits <= 4'd0;
                        cmd <= 8'd0;
                        state <= S_COMMAND;
                    end
                S_COMMAND: begin
                    cmd <= {cmd[6:0], di_q};
                    bits <= bits + 4'd1;
                    if (bits == 4'd7) begin
                        bits <= 4'd0;
                        addr <= {cmd[4:0], di_q};
                        case (cmd[6:5])
                            2'b10: begin                       // READ
                                shift <= 16'd0;
                                read_first <= 1'b1;
                                a_addr <= {cmd[4:0], di_q};
                                read_pend <= 2'b01;
                                state <= S_READ;
                            end
                            2'b01: begin                       // WRITE
                                shift <= 16'd0;
                                state <= S_DATA;
                            end
                            2'b11: begin                       // ERASE
                                if (locked)
                                    state <= S_RESET;
                                else begin
                                    a_addr <= {cmd[4:0], di_q};
                                    a_din <= 16'hffff;
                                    a_we <= 1'b1;
                                    nv_dirty <= 1'b1;
                                    busy <= T_ERASE;
                                    state <= S_DONE;
                                end
                            end
                            default:                           // 00: by the address's top bits
                                case (cmd[4:3])
                                    2'b00: begin               // EWDS
                                        locked <= 1'b1;
                                        state <= S_RESET;
                                    end
                                    2'b01: begin               // WRAL
                                        shift <= 16'd0;
                                        state <= S_DATA;
                                    end
                                    2'b10: begin               // ERAL
                                        if (locked)
                                            state <= S_RESET;
                                        else begin
                                            all_op <= 2'd1;
                                            all_i <= 6'd0;
                                            busy <= T_ALL;
                                            state <= S_DONE;
                                        end
                                    end
                                    default: begin             // EWEN
                                        locked <= 1'b0;
                                        state <= S_RESET;
                                    end
                                endcase
                        endcase
                    end
                end
                S_READ: begin
                    read_first <= 1'b0;
                    shift <= read_first ? read_word : {shift[14:0], 1'b1};
                end
                S_DATA: begin
                    shift <= {shift[14:0], di_q};
                    bits <= bits + 4'd1;
                    if (bits == 4'd15) begin
                        bits <= 4'd0;
                        if (locked)
                            state <= S_RESET;
                        else if (cmd[7:6] == 2'b01) begin       // WRITE
                            a_addr <= addr;
                            a_din <= {shift[14:0], di_q};
                            a_we <= 1'b1;
                            nv_dirty <= 1'b1;
                            busy <= T_WRITE;
                            state <= S_DONE;
                        end else begin                         // WRAL
                            all_op <= 2'd2;
                            all_i <= 6'd0;
                            all_ph <= 2'd0;
                            all_data <= {shift[14:0], di_q};
                            busy <= T_ALL;
                            state <= S_DONE;
                        end
                    end
                end
                default: ;
            endcase
        end

    end
end

endmodule
