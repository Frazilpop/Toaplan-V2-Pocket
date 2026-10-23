// The RAM the 68000 and the V25 share: a true dual-port RAM on one clock
// whose read of a byte the other port is writing in the same clock returns
// the old byte, on the FPGA as in simulation.
//
// jtframe_dual_ram (ramstyle "no_rw_check") lets Quartus make that case
// DONT_CARE, and it did: the M10K then returns an undefined byte. The
// simulation always reads the old one, so it never shows. It matters where
// one CPU polls a byte the other writes, as the V25's boot code polls the
// upload FIFO's write pointer at 28e9e8 while the 68000 fills it (FixEight,
// Dogyuun, Grind Stormer, batsugunc): one bad pointer read and the V25 takes
// bytes that are not there yet, and the upload is lost.
//
// Same-port reads during a write are new data, as before; neither CPU reads
// the RAM in the cycle it writes it.
module toaplan_shared_ram #(
    parameter integer DW = 8,
    parameter integer AW = 15
) (
    input               clk,
    input      [AW-1:0] addr0,
    input      [DW-1:0] data0,
    input               we0,
    output     [DW-1:0] q0,
    input      [AW-1:0] addr1,
    input      [DW-1:0] data1,
    input               we1,
    output     [DW-1:0] q1
);

`ifdef VERILATOR
reg [DW-1:0] mem [0:(2**AW)-1];
reg [DW-1:0] qq0 = '0, qq1 = '0;
integer i;
initial for (i = 0; i < 2**AW; i = i + 1) mem[i] = '0;

always @(posedge clk) begin
    qq0 <= mem[addr0];
    if (we0) mem[addr0] <= data0;
end
always @(posedge clk) begin
    qq1 <= mem[addr1];
    if (we1) mem[addr1] <= data1;
end
assign q0 = qq0;
assign q1 = qq1;
`else
altsyncram #(
    .operation_mode                     ("BIDIR_DUAL_PORT"),
    .intended_device_family             ("Cyclone V"),
    .lpm_type                           ("altsyncram"),
    .ram_block_type                     ("M10K"),
    .width_a                            (DW),
    .widthad_a                          (AW),
    .numwords_a                         (2**AW),
    .width_b                            (DW),
    .widthad_b                          (AW),
    .numwords_b                         (2**AW),
    .width_byteena_a                    (1),
    .width_byteena_b                    (1),
    .address_reg_b                      ("CLOCK0"),
    .indata_reg_b                       ("CLOCK0"),
    .wrcontrol_wraddress_reg_b          ("CLOCK0"),
    .outdata_reg_a                      ("UNREGISTERED"),
    .outdata_reg_b                      ("UNREGISTERED"),
    .outdata_aclr_a                     ("NONE"),
    .outdata_aclr_b                     ("NONE"),
    .clock_enable_input_a               ("BYPASS"),
    .clock_enable_input_b               ("BYPASS"),
    .clock_enable_output_a              ("BYPASS"),
    .clock_enable_output_b              ("BYPASS"),
    .power_up_uninitialized             ("FALSE"),
    .read_during_write_mode_mixed_ports ("OLD_DATA"),
    .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ")
) u_ram (
    .clock0         (clk),
    .address_a      (addr0),
    .data_a         (data0),
    .wren_a         (we0),
    .q_a            (q0),
    .address_b      (addr1),
    .data_b         (data1),
    .wren_b         (we1),
    .q_b            (q1),
    .aclr0          (1'b0),
    .aclr1          (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .byteena_a      (1'b1),
    .byteena_b      (1'b1),
    .clock1         (1'b1),
    .clocken0       (1'b1),
    .clocken1       (1'b1),
    .clocken2       (1'b1),
    .clocken3       (1'b1),
    .eccstatus      (),
    .rden_a         (1'b1),
    .rden_b         (1'b1)
);
`endif

endmodule
