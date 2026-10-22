// Toaplan V2 ROM image (<set>.rom) to JTFrame SDRAM programming bridge.
//
// The image is a 4 KB header, then the set's regions at the offsets its
// region table gives (tools/pocket/build_rom.py). The header is not written
// to SDRAM: its configuration bytes are captured into the cfg_* outputs and
// the region table maps every later byte to its SDRAM bank:
//
//   maincpu  -> bank 0        gp9001_0 -> bank 1       gp9001_1 -> bank 2
//   oki      -> bank 3 at 0   audiocpu -> bank 3 at AUDIO_BASE bytes,
//                                         and the audio_* port (TP-023's
//                                         V25 ROM, 32 KB, into block RAM)
//   eeprom   -> the eeprom_* port (byte address, 128 bytes)
//
// Clocks are held as the Hz the header gives and decoded into the board's
// enable ratios at 94.5 MHz: the 68000 and V25 rate num/189, the OKI's an
// increment over a wrap.
//
// Every slot starts on a 4 KB boundary and all but the EEPROM's 128 bytes
// are whole 4 KB pages, so a byte's region is found by its page (15 bits)
// and the region in three stages: the byte registered, its region, its bank
// address; then the pairing into SDRAM words.
module dogyuun_rom_loader #(
    parameter integer AW = 22,
    parameter [26:0]  AUDIO_BASE = 27'h0040000
) (
    input                   clk,
    input                   rst,

    input                   ioctl_rom,
    input      [26:0]       ioctl_addr,
    input      [7:0]        ioctl_dout,
    input                   ioctl_wr,

    output                  dwnld_busy,
    output reg [1:0]        prog_ba,
    output reg [AW-1:0]     prog_addr,
    output reg [15:0]       prog_data,
    output reg [1:0]        prog_mask,
    output                  prog_rd,
    output reg              prog_we,
    input                   prog_rdy,
    input                   prog_ack,

    // The header, valid from the end of the header on.
    output reg              cfg_valid,
    output reg [2:0]        cfg_board,
    output reg              cfg_two_gp,
    output reg              cfg_rot0,       // MAME ROT0 (Knuckle Bash); else ROT270
    output reg [1:0]        cfg_table,
    output reg              cfg_oki_pin7,
    output reg              cfg_wram_64k,
    output reg [6:0]        cfg_cpu_num,
    output reg [6:0]        cfg_v25_num,
    output reg [4:0]        cfg_oki_inc,
    output reg [11:0]       cfg_oki_wrap,
    output reg [7:0]        cfg_dswa,
    output reg [7:0]        cfg_dswb,
    output reg [7:0]        cfg_jmpr,
    output reg [1:0]        cfg_gp0_size,   // 0: 2 MB, 1: 4 MB, 2: 8 MB
    output reg [1:0]        cfg_gp1_size,

    output reg              audio_we,
    output reg [14:0]       audio_addr,
    output reg [7:0]        audio_data,

    output reg              eeprom_we,
    output reg [6:0]        eeprom_addr,
    output reg [7:0]        eeprom_data,

    output reg              accepted,
    output reg              range_error,
    output reg              overflow_error,
    output reg [26:0]       last_addr
);

localparam [26:0] HEADER_END = 27'h0001000;
localparam integer REGIONS = 6;     // maincpu, audiocpu, gp9001_0, gp9001_1, oki, eeprom

reg [31:0] cpu_hz, v25_hz, oki_hz;
reg [31:0] magic;
reg [7:0]  dips_valid;
reg [31:0] image_len;
reg [26:0] reg_off [0:REGIONS-1];
reg [26:0] reg_len [0:REGIONS-1];
reg [14:0] pg_off [0:REGIONS-1];   // first and one-past-last 4 KB page
reg [14:0] pg_end [0:REGIONS-1];

function automatic [6:0] rate_num;      // 94.5 MHz x num / 189
    input [31:0] hz;
    begin
        case (hz)
            32'd16000000: rate_num = 7'd32;
            32'd10000000: rate_num = 7'd20;
            default:      rate_num = 7'd25;   // 12.5 MHz
        endcase
    end
endfunction

function automatic [16:0] oki_rate;     // {inc[4:0], wrap[11:0]}
    input [31:0] hz;
    begin
        case (hz)
            32'd4000000:  oki_rate = {5'd8,  12'd189};   // 32 MHz / 8
            32'd1041667:  oki_rate = {5'd25, 12'd2268};  // 25 MHz / 24
            32'd1000000:  oki_rate = {5'd2,  12'd189};
            default:      oki_rate = {5'd0,  12'd189};   // no OKI
        endcase
    end
endfunction

function automatic [1:0] gfx_size;
    input [26:0] len;
    begin
        gfx_size = len[23] ? 2'd2 : len[22] ? 2'd1 : 2'd0;
    end
endfunction

// Stage 1: the incoming byte, registered.
reg        s1_wr;
reg [26:0] s1_addr;
reg [7:0]  s1_data;

reg [REGIONS-1:0] s1_hit;
integer r;
always @(*) begin
    for (r = 0; r < REGIONS; r = r + 1)
        s1_hit[r] = (s1_addr[26:12] >= pg_off[r]) && (s1_addr[26:12] < pg_end[r]);
    // the EEPROM's 128 bytes are part of a page
    s1_hit[5] = s1_hit[5] && s1_addr[11:7] == 5'd0;
end

// Stage 2: its region (7: none) and its page in the region.
reg        s2_wr;
reg [26:0] s2_addr;
reg [7:0]  s2_data;
reg [2:0]  s2_region;

// Stage 3: bank and byte address in the bank.
reg        s3_wr;
reg [7:0]  s3_data;
reg [2:0]  s3_region;
reg [1:0]  s3_bank;
reg [26:0] s3_byte;
reg        s3_header;
reg [26:0] s3_addr;

wire [14:0] s2_page_local = s2_addr[26:12] - pg_off[s2_region];
wire [26:0] s2_local = {s2_page_local[14:0], s2_addr[11:0]};
wire [AW-1:0] s3_word = s3_byte[AW:1];
wire s3_sdram = s3_region <= 3'd4;
wire [14:0] s3_local_audio = s3_byte[14:0];   // AUDIO_BASE is 32 KB-aligned

always @(posedge clk) begin
    if (rst) begin
        s2_wr <= 1'b0;
        s3_wr <= 1'b0;
        s2_region <= 3'd7;
        s3_region <= 3'd7;
    end else begin
        s2_wr <= s1_wr;
        s2_addr <= s1_addr;
        s2_data <= s1_data;
        s2_region <= s1_hit[0] ? 3'd0 : s1_hit[1] ? 3'd1 : s1_hit[2] ? 3'd2 :
                     s1_hit[3] ? 3'd3 : s1_hit[4] ? 3'd4 : s1_hit[5] ? 3'd5 : 3'd7;
        s3_wr <= s2_wr;
        s3_data <= s2_data;
        s3_region <= s2_region;
        s3_addr <= s2_addr;
        s3_header <= s2_addr < HEADER_END;
        s3_bank <= (s2_region == 3'd0) ? 2'd0 : (s2_region == 3'd2) ? 2'd1 :
                   (s2_region == 3'd3) ? 2'd2 : 2'd3;
        s3_byte <= (s2_region == 3'd1) ? s2_local + AUDIO_BASE : s2_local;
    end
end

wire can_accept = !prog_we || prog_ack;
reg pair_valid;
reg [7:0] pair_even_data;
reg [1:0] pair_bank;
reg [AW-1:0] pair_word_addr;

assign prog_rd = 1'b0;
assign dwnld_busy = ioctl_rom || s1_wr || s2_wr || s3_wr || prog_we || pair_valid;

always @(posedge clk) begin
    if (rst) begin
        s1_wr <= 1'b0;
        s1_addr <= 27'd0;
        s1_data <= 8'd0;
    end else begin
        s1_wr <= ioctl_wr && ioctl_rom;
        if (ioctl_wr && ioctl_rom) begin
            s1_addr <= ioctl_addr;
            s1_data <= ioctl_dout;
        end
    end
end

// The header's bytes.
integer k;
always @(posedge clk) begin
    eeprom_we <= 1'b0;
    audio_we <= 1'b0;
    if (rst) begin
        magic <= 32'd0;
        cfg_board <= 3'd0;
        cfg_two_gp <= 1'b1;
        cfg_rot0 <= 1'b0;
        cfg_table <= 2'd0;
        cfg_oki_pin7 <= 1'b0;
        cfg_wram_64k <= 1'b1;
        cpu_hz <= 32'd0;
        v25_hz <= 32'd0;
        oki_hz <= 32'd0;
        cfg_dswa <= 8'h00;
        cfg_dswb <= 8'h00;
        cfg_jmpr <= 8'h00;
        dips_valid <= 8'h00;
        image_len <= 32'd0;
        for (k = 0; k < REGIONS; k = k + 1) begin
            reg_off[k] <= 27'd0;
            reg_len[k] <= 27'd0;
        end
        eeprom_addr <= 7'd0;
        eeprom_data <= 8'd0;
        audio_addr <= 15'd0;
        audio_data <= 8'd0;
    end else if (s1_wr && s1_addr < HEADER_END) begin
        case (s1_addr[11:0])
            12'h000: magic[7:0]   <= s1_data;
            12'h001: magic[15:8]  <= s1_data;
            12'h002: magic[23:16] <= s1_data;
            12'h003: magic[31:24] <= s1_data;
            12'h005: cfg_board    <= s1_data[2:0];
            12'h006: cfg_two_gp   <= s1_data == 8'd2;
            12'h007: cfg_table    <= s1_data[1:0];
            12'h008: cfg_rot0     <= s1_data == 8'd0;
            12'h00a: cfg_oki_pin7 <= s1_data == 8'd1;
            12'h00b: cfg_wram_64k <= s1_data == 8'd64;
            12'h018: cfg_dswa     <= s1_data;
            12'h019: cfg_dswb     <= s1_data;
            12'h01a: cfg_jmpr     <= s1_data;
            12'h01b: dips_valid   <= s1_data;
            default: ;
        endcase
        case (s1_addr[11:2])
            10'h003: cpu_hz[8*s1_addr[1:0] +: 8] <= s1_data;
            10'h004: v25_hz[8*s1_addr[1:0] +: 8] <= s1_data;
            10'h005: oki_hz[8*s1_addr[1:0] +: 8] <= s1_data;
            10'h007: image_len[8*s1_addr[1:0] +: 8] <= s1_data;
            default: ;
        endcase
        // Region table, 0x020-0x04f: (offset, length) pairs, 32-bit LE.
        if (s1_addr[11:0] >= 12'h020 && s1_addr[11:0] < 12'h050) begin
            if (s1_addr[2] == 1'b0) begin
                if (s1_addr[1:0] != 2'd3)
                    reg_off[(s1_addr[11:0] - 12'h020) >> 3][8*s1_addr[1:0] +: 8] <= s1_data;
                else
                    reg_off[(s1_addr[11:0] - 12'h020) >> 3][26:24] <= s1_data[2:0];
            end else begin
                if (s1_addr[1:0] != 2'd3)
                    reg_len[(s1_addr[11:0] - 12'h020) >> 3][8*s1_addr[1:0] +: 8] <= s1_data;
                else
                    reg_len[(s1_addr[11:0] - 12'h020) >> 3][26:24] <= s1_data[2:0];
            end
        end
    end
    if (s3_wr && !s3_header && s3_region == 3'd5) begin
        eeprom_we   <= 1'b1;
        eeprom_addr <= s3_byte[6:0];
        eeprom_data <= s3_data;
    end
    if (s3_wr && !s3_header && s3_region == 3'd1) begin
        audio_we   <= 1'b1;
        audio_addr <= s3_local_audio;
        audio_data <= s3_data;
    end
end

// Decoded once the header is in; cfg_valid stays up until the next reset.
always @(posedge clk) begin
    if (rst) begin
        cfg_valid <= 1'b0;
        cfg_cpu_num <= 7'd25;
        cfg_v25_num <= 7'd25;
        cfg_oki_inc <= 5'd25;
        cfg_oki_wrap <= 12'd2268;
        cfg_gp0_size <= 2'd0;
        cfg_gp1_size <= 2'd1;
    end else if (s1_wr && s1_addr == HEADER_END - 1'b1) begin
        cfg_valid <= magic == 32'h32565054;       // "TPV2"
        cfg_cpu_num <= rate_num(cpu_hz);
        cfg_v25_num <= rate_num(v25_hz);
        {cfg_oki_inc, cfg_oki_wrap} <= oki_rate(oki_hz);
        cfg_gp0_size <= gfx_size(reg_len[2]);
        cfg_gp1_size <= gfx_size(reg_len[3]);
    end
end

// The regions' pages, once the region table is in (by 0x050; the header's
// last byte is far later).
integer q;
always @(posedge clk) begin
    if (rst) begin
        for (q = 0; q < REGIONS; q = q + 1) begin
            pg_off[q] <= 15'd0;
            pg_end[q] <= 15'd0;
        end
    end else if (s1_wr && s1_addr == 27'h0000060) begin
        for (q = 0; q < REGIONS; q = q + 1) begin
            pg_off[q] <= reg_off[q][26:12];
            pg_end[q] <= reg_off[q][26:12] + reg_len[q][26:12] +
                         (reg_len[q][11:0] != 12'd0 ? 15'd1 : 15'd0);
        end
    end
end

// Pair adjacent bytes of a region into one unmasked SDRAM write. The even
// byte goes in the SDRAM low lane, preserving upstream's 68000 word swap,
// graphics layout, and byte order seen by JTFrame's 8-bit OKI reader.
always @(posedge clk) begin
    accepted <= 1'b0;
    if (rst) begin
        prog_ba       <= 2'd0;
        prog_addr     <= {AW{1'b0}};
        prog_data     <= 16'h0000;
        prog_mask     <= 2'b11;
        prog_we       <= 1'b0;
        range_error   <= 1'b0;
        overflow_error <= 1'b0;
        last_addr     <= 27'd0;
        pair_valid    <= 1'b0;
        pair_even_data <= 8'd0;
        pair_bank     <= 2'd0;
        pair_word_addr <= {AW{1'b0}};
    end else begin
        if (prog_we && prog_ack)
            prog_we <= 1'b0;

        // An interrupted transfer must not leave the game held in reset by a
        // permanently buffered half-word.
        if (!ioctl_rom && !s1_wr && !s2_wr && !s3_wr)
            pair_valid <= 1'b0;

        if (s3_wr) begin
            last_addr <= s3_addr;
            if (s3_header || s3_region == 3'd5) begin
                // header and EEPROM bytes: handled above
            end else if (!s3_sdram) begin
                // A byte in no region: the gaps between slots are zero, and
                // the end of the image may be padded. Not ROM data.
                if (s3_data != 8'h00 &&
                    !(image_len != 32'd0 && s3_addr >= image_len[26:0]))
                    range_error <= 1'b1;
            end else if (can_accept) begin
                if (!s3_byte[0]) begin
                    if (pair_valid) begin
                        overflow_error <= 1'b1;
                    end else begin
                        pair_even_data <= s3_data;
                        pair_bank <= s3_bank;
                        pair_word_addr <= s3_word;
                        pair_valid <= 1'b1;
                        accepted <= 1'b1;
                    end
                end else if (!pair_valid ||
                             pair_bank != s3_bank ||
                             pair_word_addr != s3_word) begin
                    // Fail visibly on a missing or non-adjacent first byte,
                    // then release the partial pair so reset cannot stick.
                    overflow_error <= 1'b1;
                    pair_valid <= 1'b0;
                end else begin
                    prog_ba   <= pair_bank;
                    prog_addr <= pair_word_addr;
                    prog_data <= {s3_data, pair_even_data};
                    prog_mask <= 2'b00;
                    prog_we   <= 1'b1;
                    pair_valid <= 1'b0;
                    accepted  <= 1'b1;
                end
            end else begin
                overflow_error <= 1'b1;
            end
        end

        // prog_rdy is deliberately not used as an acceptance pulse. A request
        // is held stable until prog_ack; the upstream MiSTer bridge uses the
        // programming ready/write state to apply download backpressure.
    end
end

endmodule
