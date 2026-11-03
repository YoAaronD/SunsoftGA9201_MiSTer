// One-clock block RAM with a read/write port A and a read-only port B, built
// as ONE true-dual-port M10K memory.
//
// Written behaviourally, a RAM with a write port and two read addresses makes
// Quartus build two simple-dual-port copies (each written, each read once).
// That is what the MiSTer build does for the draw buffer and the work RAM, and
// the Pocket's FPGA (308 M10K) has no room for the second copies. Used only
// in the Pocket build (`POCKET), from rtl/shangha3_video.sv and
// rtl/shangha3_board.sv.
//
// Read-during-write: port B reading the address port A writes in the same
// clock gets the old data, as with the two copies. Port A's own read in a
// write clock is not used by its callers (see there).
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).

module pocket_tdp_ram #(
    parameter int AW    = 15,
    parameter int DW    = 8,
    parameter int WORDS = 1 << AW
) (
    input  logic          clk,
    input  logic [AW-1:0] a_addr,
    input  logic          a_we,
    input  logic [DW-1:0] a_d,
    output logic [DW-1:0] a_q,
    input  logic [AW-1:0] b_addr,
    output logic [DW-1:0] b_q
);
`ifdef VERILATOR
    logic [DW-1:0] mem [0:WORDS-1];
    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_d;
        a_q <= mem[a_addr];
        b_q <= mem[b_addr];
    end
`else
    altsyncram #(
        .operation_mode                     ("BIDIR_DUAL_PORT"),
        .intended_device_family             ("Cyclone V"),
        .ram_block_type                     ("M10K"),
        .lpm_type                           ("altsyncram"),
        .width_a                            (DW),
        .widthad_a                          (AW),
        .numwords_a                         (WORDS),
        .width_b                            (DW),
        .widthad_b                          (AW),
        .numwords_b                         (WORDS),
        .width_byteena_a                    (1),
        .width_byteena_b                    (1),
        .outdata_reg_a                      ("UNREGISTERED"),
        .outdata_reg_b                      ("UNREGISTERED"),
        .address_reg_b                      ("CLOCK0"),
        .indata_reg_b                       ("CLOCK0"),
        .wrcontrol_wraddress_reg_b          ("CLOCK0"),
        .outdata_aclr_a                     ("NONE"),
        .outdata_aclr_b                     ("NONE"),
        .clock_enable_input_a               ("BYPASS"),
        .clock_enable_input_b               ("BYPASS"),
        .clock_enable_output_a              ("BYPASS"),
        .clock_enable_output_b              ("BYPASS"),
        .power_up_uninitialized             ("FALSE"),
        .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports ("OLD_DATA")
    ) u_ram (
        .clock0         (clk),
        .address_a      (a_addr),
        .wren_a         (a_we),
        .data_a         (a_d),
        .q_a            (a_q),
        .address_b      (b_addr),
        .wren_b         (1'b0),
        .data_b         ({DW{1'b0}}),
        .q_b            (b_q),
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
