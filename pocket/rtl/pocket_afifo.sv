// Small asynchronous FIFO (Gray-coded pointers, two-flop synchronisers).
// Used for the APF bridge (74.25 MHz) -> core (96 MHz) crossing.
// Write side: push when !full. Read side: dout is the head entry while !empty
// (show-ahead); pop to advance.
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).

module pocket_afifo #(
    parameter int W  = 32,
    parameter int AW = 4                // depth = 2**AW
) (
    input  logic         wclk,
    input  logic         wrst,
    input  logic         push,
    input  logic [W-1:0] din,
    output logic         full,

    input  logic         rclk,
    input  logic         rrst,
    input  logic         pop,
    output logic [W-1:0] dout,
    output logic         empty
);
    (* ramstyle = "logic" *) logic [W-1:0] mem [0:(1<<AW)-1];

    logic [AW:0] wbin, wgray, rbin, rgray;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [AW:0] rgray_w1, rgray_w2;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [AW:0] wgray_r1, wgray_r2;

    function automatic logic [AW:0] b2g(input logic [AW:0] b);
        return b ^ (b >> 1);
    endfunction

    // write side
    wire [AW:0] wbin_n  = wbin + (AW+1)'(push && !full);
    always_ff @(posedge wclk) begin
        if (wrst) begin
            wbin  <= '0;
            wgray <= '0;
            rgray_w1 <= '0;
            rgray_w2 <= '0;
        end else begin
            if (push && !full) mem[wbin[AW-1:0]] <= din;
            wbin  <= wbin_n;
            wgray <= b2g(wbin_n);
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
        end
    end
    assign full = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});

    // read side
    wire [AW:0] rbin_n = rbin + (AW+1)'(pop && !empty);
    always_ff @(posedge rclk) begin
        if (rrst) begin
            rbin  <= '0;
            rgray <= '0;
            wgray_r1 <= '0;
            wgray_r2 <= '0;
        end else begin
            rbin  <= rbin_n;
            rgray <= b2g(rbin_n);
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
        end
    end
    assign empty = (rgray == wgray_r2);
    assign dout  = mem[rbin[AW-1:0]];
endmodule
