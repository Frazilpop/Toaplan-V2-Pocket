// The 68000's clock enables and /DTACK, at 94.5 MHz x num / 189 (32: 16 MHz,
// 25: 12.5 MHz), with the wait states the board's memories cost given back.
//
// The boards' 68000 runs without wait states (MAME's machine configs), but
// here a program ROM read waits for the SDRAM and a GP9001 access for its
// register side. fx68k samples /DTACK on each enPhi2 (cpu_cenb): the second
// enPhi2 after /AS falls is in S4, and each enPhi2 from there on that sees
// /DTACK high costs one CPU clock (two enables). Exactly those are counted
// and given back, as extra enables while the bus is idle, so the CPU keeps
// MAME's rate: the 38-cycle loop Batsugun runs in its first frames goes 7,060
// times a frame, as in MAME (jtframe_68kdtack_cen, which this replaces,
// counted every enable a slow access was busy across and ran 5.3 % fast).
module dogyuun_68k_cen (
    input            clk,
    input            rst,
    input      [6:0] num,
    input            ASn,
    input      [1:0] DSn,
    input            bus_busy,
    output reg       cpu_cen,
    output reg       cpu_cenb,
    output reg       DTACKn
);

localparam [7:0] DEN = 8'd189;

reg [7:0]  acc;
reg        phase;        // the next enable is cpu_cen (0) or cpu_cenb (1)
reg [15:0] missing;
reg        wait1;
reg        cenb_seen;    // an enPhi2 has passed with /AS low (S2)

wire [7:0] num2 = {num, 1'b0};
wire       over = acc >= DEN - num2;
wire       stall = cpu_cenb && !ASn && cenb_seen && DTACKn;
wire       recover = ASn && !over && missing != 16'd0;

always @(posedge clk) begin
    if (rst) begin
        acc <= 8'd0;
        phase <= 1'b0;
        cpu_cen <= 1'b0;
        cpu_cenb <= 1'b0;
        missing <= 16'd0;
    end else begin
        acc <= over ? acc + num2 - DEN : acc + num2;
        cpu_cen <= 1'b0;
        cpu_cenb <= 1'b0;
        if (over || recover) begin
            cpu_cen <= !phase;
            cpu_cenb <= phase;
            phase <= !phase;
        end
        // A wait state seen now is two enables to give back; one is given
        // back at each recovered enable.
        missing <= missing + (stall ? 16'd2 : 16'd0) - (recover ? 16'd1 : 16'd0);
    end
end

// /DTACK as jtframe's generator: high while /AS (or both /DS) is high, then
// low from the second clock of the cycle on once the access is not busy.
// A write's /DS falls a clock after /AS (S2 to S4), so the deadline enPhi2
// is still the second after /AS, whatever /DS does.
always @(posedge clk) begin
    if (rst) begin
        DTACKn <= 1'b1;
        wait1 <= 1'b1;
        cenb_seen <= 1'b0;
    end else begin
        if (ASn || &DSn) begin
            DTACKn <= 1'b1;
            wait1 <= 1'b1;
        end else begin
            wait1 <= 1'b0;
            if (!wait1)
                DTACKn <= DTACKn && bus_busy;
        end
        if (ASn)
            cenb_seen <= 1'b0;
        else if (cpu_cenb)
            cenb_seen <= 1'b1;
    end
end

endmodule
