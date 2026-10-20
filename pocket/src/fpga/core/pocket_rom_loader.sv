// SPDX-License-Identifier: GPL-3.0-or-later
// Toaplan V2 for Analogue Pocket — APF data slot -> the board's ioctl byte
// stream, and `rom_loaded`
//
// The .rom image is loaded by APF at bridge address 0, four bytes per bridge
// write, on clk_74a. The board's own loader (dogyuun_rom_loader) takes it as
// a byte stream on its ioctl_* port, MiSTer-style: it reads the 4 KB header,
// then places every later byte in its SDRAM bank, pairing bytes into words
// and writing them through jtframe_sdram64's programming port. So all this
// does is cross the bytes into the board clock and pace them.
//
// THREE STAGES
//
// 1. data_loader (agg23, MIT, third_party/pocket-utils) crosses the bridge
//    writes into the 94.5 MHz domain through a dcfifo and splits each 32-bit
//    write into four bytes in file order (with bridge_endian_little = 0 it
//    byte-swaps first, so byte 4k comes out first, at address 4k). It has no
//    back-pressure: a byte every WRITE_MEM_CLOCK_DELAY clocks.
//
// 2. A FIFO of bytes, because the board's loader does have back-pressure.
//    APF delivers about one bridge word per microsecond (~95 clocks, four
//    bytes); the board takes a byte in five clocks plus an SDRAM write per
//    pair, so the FIFO rarely holds more than a few. Overflow is counted
//    rather than assumed away (the overlay shows it).
//
// 3. The pacer. The board's loader needs a byte at most every five clocks:
//    it registers the byte, finds its region, then its bank address (three
//    stages), then pairs it with the one before and raises prog_we for the
//    SDRAM write, which stays up until the controller acknowledges it. A
//    byte arriving while prog_we is up would overrun the pair. So: one
//    byte, four idle clocks, then wait for prog_we to be low — exactly the
//    harness's send() (sim/batsugun/tb_batsugun.cpp), which streams whole
//    images through the same loader into the same controller.
//
// WHEN IS THE ROM LOADED
//
// APF sends [008F Data slot access all complete] after its last slot write
// (core_bridge_cmd raises dataslot_allcomplete). rom_loaded waits for that
// AND an empty pipeline held for QUIET clocks, then drops ioctl_rom; the
// board's dwnld_busy falls once its own stages have drained. Once high it
// stays high — APF clears allcomplete again for the shutdown read-out, and
// the ROM is still there.

`default_nettype none

module pocket_rom_loader #(
    parameter int unsigned QUIET = 1024
)(
    input  wire              clk_74a,
    input  wire              bridge_wr,
    input  wire              bridge_endian_little,
    input  wire [31:0]       bridge_addr,
    input  wire [31:0]       bridge_wr_data,

    input  wire              clk,            // 94.5 MHz, the board's
    input  wire              rst,            // power-on only
    input  wire              allcomplete_s,  // dataslot_allcomplete, synchronised

    // the board's ioctl port
    output reg               ioctl_rom,
    output reg               ioctl_wr,
    output reg  [26:0]       ioctl_addr,
    output reg  [7:0]        ioctl_dout,
    input  wire              prog_we,

    output reg               rom_loaded,
    output reg  [26:0]       bytes,          // how many bytes have gone in
    output reg               overflow        // sticky
);

    // ------------------------------------------------------ 74 -> 94.5 MHz
    wire        ld_wr;
    wire [27:0] ld_addr;
    wire [7:0]  ld_data;

    data_loader #(
        .ADDRESS_MASK_UPPER_4 (4'h0),
        .ADDRESS_SIZE         (28),
        .WRITE_MEM_CLOCK_DELAY(8),
        .WRITE_MEM_EN_CYCLE_LENGTH(1),
        .OUTPUT_WORD_SIZE     (1)
    ) u_loader (
        .clk_74a             (clk_74a),
        .clk_memory          (clk),
        .bridge_wr           (bridge_wr),
        .bridge_endian_little(bridge_endian_little),
        .bridge_addr         (bridge_addr),
        .bridge_wr_data      (bridge_wr_data),
        .write_en            (ld_wr),
        .write_addr          (ld_addr),
        .write_data          (ld_data)
    );

    // ------------------------------------------------------------- FIFO
    localparam int unsigned FD = 32;            // entries
    localparam int unsigned FA = $clog2(FD);

    reg [34:0]  fifo [FD];                      // {byte address, byte}
    reg [FA:0]  wp, rp;                         // one extra bit: full vs empty
    wire        f_empty = (wp == rp);
    wire        f_full  = (wp[FA-1:0] == rp[FA-1:0]) && (wp[FA] != rp[FA]);

    always @(posedge clk) begin
        if (rst) begin
            wp       <= '0;
            overflow <= 1'b0;
        end else if (ld_wr && ld_addr[27] == 1'b0) begin
            if (f_full) overflow <= 1'b1;
            else begin
                fifo[wp[FA-1:0]] <= {ld_addr[26:0], ld_data};
                wp <= wp + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ pacer
    reg [2:0] gap;                              // idle clocks still owed
    reg [$clog2(QUIET+1)-1:0] quiet;

    always @(posedge clk) begin
        ioctl_wr <= 1'b0;
        if (rst) begin
            rp         <= '0;
            gap        <= 3'd0;
            quiet      <= '0;
            ioctl_rom  <= 1'b1;
            rom_loaded <= 1'b0;
            ioctl_addr <= 27'd0;
            ioctl_dout <= 8'd0;
            bytes      <= 27'd0;
        end else begin
            if (gap != 3'd0) begin
                gap <= gap - 3'd1;
            end else if (!f_empty && !prog_we && ioctl_rom) begin
                {ioctl_addr, ioctl_dout} <= fifo[rp[FA-1:0]];
                ioctl_wr <= 1'b1;
                rp       <= rp + 1'b1;
                gap      <= 3'd4;
                bytes    <= bytes + 27'd1;
            end

            if (!allcomplete_s || !f_empty || ld_wr || gap != 3'd0 || ioctl_wr)
                quiet <= '0;
            else if (quiet != QUIET[$bits(quiet)-1:0])
                quiet <= quiet + 1'b1;
            else begin
                rom_loaded <= 1'b1;
                ioctl_rom  <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
