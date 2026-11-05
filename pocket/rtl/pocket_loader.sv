// APF bridge -> MiSTer-style ioctl byte stream.
//
// The Pocket delivers a data slot as 32-bit bridge writes (clk_74a, big
// endian: bits 31:24 are the byte at the lowest address). The ROM slot sits at
// bridge addresses 0x00000000-0x0FFFFFFF. Each word goes through a small
// asynchronous FIFO into the core clock domain and is replayed as four
// ioctl_wr byte strobes, honouring ioctl_wait exactly like the MiSTer's hps_io
// does (strobe, two clocks, then wait while ioctl_wait is high). The core's
// memory system therefore sees the same stream as on the MiSTer.
//
// The APF host sends one word roughly every 75 clk_74a cycles (~1 us); the
// SDRAM writer takes about 12 clk cycles per byte, so the FIFO stays short.
//
// ioctl_download is high from the first word until the host has released the
// core from reset (APF "reset exit", sent after all data slots are loaded) and
// every byte has been written. It rises 16 clocks before the first byte, as
// the MiSTer's hps_io does.
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).

module pocket_loader (
    // APF side (clk_74a)
    input  logic        clk_74a,
    input  logic        bridge_wr,
    input  logic [31:0] bridge_addr,
    input  logic [31:0] bridge_wr_data,
    input  logic        running,          // reset_n from the APF host (clk_74a)

    // core side
    input  logic        clk,
    input  logic        reset,            // core power-up reset (PLL not locked)
    output logic        ioctl_download,
    output logic        ioctl_wr,
    output logic [26:0] ioctl_addr,
    output logic [7:0]  ioctl_dout,
    input  logic        ioctl_wait,
    output logic        overflow          // sticky: a bridge word was dropped (FIFO full)
);
    // ------------------------------------------------------------------
    // clk_74a: capture ROM-slot writes
    // ------------------------------------------------------------------
    logic        wr_q, push, full;
    logic [56:0] din;                 // {word address [26:2], data}
    logic        rst74_1, rst74;
    logic        ovf74;
    // Data slots are only loaded while the APF holds the core in reset; once
    // it runs, writes here are ignored (on hardware a save-state load seems to
    // send its first word to a wrong address, which started a "download" and
    // reset the game).
    logic        run74_1, run74;
    always_ff @(posedge clk_74a) begin
        {rst74, rst74_1} <= {rst74_1, reset};
        {run74, run74_1} <= {run74_1, running};
        wr_q <= bridge_wr;
        push <= 1'b0;
        if (bridge_wr && !wr_q && bridge_addr[31:28] == 4'h0 && !run74) begin
            push <= 1'b1;
            din  <= {bridge_addr[26:2], bridge_wr_data};
        end
        if (rst74) ovf74 <= 1'b0;
        else if (push && full) ovf74 <= 1'b1;
    end

    logic        empty, pop;
    logic [56:0] dout;
    pocket_afifo #(.W(57), .AW(4)) u_fifo (
        .wclk(clk_74a), .wrst(rst74), .push, .din, .full,
        .rclk(clk), .rrst(reset), .pop, .dout, .empty
    );

    // ------------------------------------------------------------------
    // clk: replay as bytes
    // ------------------------------------------------------------------
    logic [1:0]  ac_s, ov_s;
    always_ff @(posedge clk) begin
        ac_s <= {ac_s[0], running};
        ov_s <= {ov_s[0], ovf74};
    end
    assign overflow = ov_s[1];

    typedef enum logic [1:0] { L_IDLE, L_STROBE, L_HOLD, L_WAIT } lstate_t;
    lstate_t     st;
    logic [1:0]  bidx;
    logic [1:0]  hold;
    logic [4:0]  dly;
    logic [24:0] waddr;
    logic [31:0] wdata;

    always_ff @(posedge clk) begin
        pop      <= 1'b0;
        ioctl_wr <= 1'b0;
        if (reset) begin
            st             <= L_IDLE;
            ioctl_download <= 1'b0;
        end else begin
            case (st)
                L_IDLE:
                    if (!empty && !pop) begin
                        if (!ioctl_download) begin
                            ioctl_download <= 1'b1;
                            dly            <= 5'd16;
                        end else if (dly != 5'd0) begin
                            dly <= dly - 5'd1;
                        end else begin
                            {waddr, wdata} <= dout;
                            pop            <= 1'b1;
                            bidx           <= 2'd0;
                            st             <= L_STROBE;
                        end
                    end else if (empty && !pop && ac_s[1]) begin
                        ioctl_download <= 1'b0;
                    end
                L_STROBE: begin
                    ioctl_wr   <= 1'b1;
                    ioctl_addr <= {waddr, bidx};
                    ioctl_dout <= wdata[31 - 8*bidx -: 8];
                    hold       <= 2'd0;
                    st         <= L_HOLD;
                end
                L_HOLD: begin                  // two clocks for ioctl_wait to rise
                    hold <= hold + 2'd1;
                    if (hold == 2'd1) st <= L_WAIT;
                end
                L_WAIT:
                    if (!ioctl_wait) begin
                        bidx <= bidx + 2'd1;
                        st   <= (bidx == 2'd3) ? L_IDLE : L_STROBE;
                    end
                default: st <= L_IDLE;
            endcase
        end
    end
endmodule
