// Display frame buffer for the Analogue Pocket: stands in for the MiSTer's
// DDR3 port (Avalon-MM, 64-bit words) that rtl/shangha3_video.sv uses, and
// stores the frame in the Pocket's two cellular RAM chips.
//
// The video module packs 4 pixels per 64-bit word (pixel i in bits
// [16i+11:16i]); only 48 of the 64 bits carry data, so each word is stored as
// one 48-bit entry (3 PSRAM words). Even frame words go to chip 0, odd ones to
// chip 1; both chips run in parallel. During the vblank copy the video module
// produces one word every 4 core clocks, i.e. each chip gets 3 PSRAM words
// every 4 PSRAM clocks (48 MHz), which the burst writes sustain with margin.
// The video module's own FIFO therefore never fills, and the blitter is held
// for exactly as long as on the MiSTer (the time it takes to read the draw
// buffer).
//
// Port behaviour the video module relies on (see shangha3_video.sv):
//   write: ddr_we + burstcnt 8, one beat per clock while !ddr_busy
//   read:  ddr_rd held until !ddr_busy, then 8 x ddr_dout_ready
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).

module pocket_fb (
    input  logic        clk,                // 96 MHz
    input  logic        reset,
    output logic        ready,

    // DDR3-style slave
    output logic        ddr_busy,
    input  logic [7:0]  ddr_burstcnt,
    input  logic [28:0] ddr_addr,
    output logic [63:0] ddr_dout,
    output logic        ddr_dout_ready,
    input  logic        ddr_rd,
    input  logic [63:0] ddr_din,
    input  logic [7:0]  ddr_be,
    input  logic        ddr_we,

    // chip 0
    output logic        c0_clk,
    output logic [21:16] c0_a,
    output logic [15:0] c0_dq_o,
    output logic        c0_dq_oe,
    input  logic [15:0] c0_dq_i,
    input  logic        c0_wait,
    output logic        c0_adv_n, c0_cre, c0_ce_n, c0_oe_n, c0_we_n,
    // chip 1
    output logic        c1_clk,
    output logic [21:16] c1_a,
    output logic [15:0] c1_dq_o,
    output logic        c1_dq_oe,
    input  logic [15:0] c1_dq_i,
    input  logic        c1_wait,
    output logic        c1_adv_n, c1_cre, c1_ce_n, c1_oe_n, c1_we_n
);
    localparam logic [28:0] DDR_BASE = 29'h0600_0000;   // as in shangha3_video.sv

    // ------------------------------------------------------------------
    // Write queues: one per chip, 32 entries {index, 48-bit data}
    // ------------------------------------------------------------------
    (* ramstyle = "MLAB, no_rw_check" *) logic [61:0] wq0 [0:31];
    (* ramstyle = "MLAB, no_rw_check" *) logic [61:0] wq1 [0:31];
    logic [5:0] wp0, rp0, wp1, rp1;
    wire  [5:0] n0 = wp0 - rp0, n1 = wp1 - rp1;
    logic       pop0, pop1;

    logic [2:0]  beat;
    logic [14:0] wbase;
    logic        rd_out;                    // read in progress
    assign ddr_busy = rd_out || (n0 >= 6'd28) || (n1 >= 6'd28) || !ready;

    wire        beat_ok = ddr_we && !ddr_busy;
    wire [14:0] widx    = ((beat == 3'd0) ? 15'(ddr_addr - DDR_BASE) : wbase) + 15'(beat);
    wire [47:0] wpk     = {ddr_din[59:48], ddr_din[43:32], ddr_din[27:16], ddr_din[11:0]};

    always_ff @(posedge clk) begin
        if (reset) begin
            wp0  <= '0;
            wp1  <= '0;
            beat <= '0;
        end else if (beat_ok) begin
            if (beat == 3'd0) wbase <= 15'(ddr_addr - DDR_BASE);
            beat <= (beat == 3'(ddr_burstcnt - 8'd1)) ? 3'd0 : beat + 3'd1;
            if (!widx[0]) begin
                wq0[wp0[4:0]] <= {widx[14:1], wpk};
                wp0 <= wp0 + 6'd1;
            end else begin
                wq1[wp1[4:0]] <= {widx[14:1], wpk};
                wp1 <= wp1 + 6'd1;
            end
        end
        if (reset) begin
            rp0 <= '0;
            rp1 <= '0;
        end else begin
            if (pop0) rp0 <= rp0 + 6'd1;
            if (pop1) rp1 <= rp1 + 6'd1;
        end
    end
    wire [61:0] wq0_q = wq0[rp0[4:0]];
    wire [61:0] wq1_q = wq1[rp1[4:0]];

    // ------------------------------------------------------------------
    // Reads: one 8-word burst = 4 entries from each chip, returned in order
    // ------------------------------------------------------------------
    logic        rq;                        // request pending at both controllers
    logic        ack0, ack1, got0, got1;
    logic [13:0] ridx;
    logic        rv0, rv1;
    logic [47:0] rd0, rd1;
    (* ramstyle = "logic" *) logic [47:0] rf0 [0:3];
    (* ramstyle = "logic" *) logic [47:0] rf1 [0:3];
    logic [2:0]  rw0, rw1, rr0, rr1;        // read FIFO pointers
    logic [3:0]  rcnt;                      // words returned (0..8)

    function automatic logic [63:0] unpack(input logic [47:0] e);
        return {4'b0, e[47:36], 4'b0, e[35:24], 4'b0, e[23:12], 4'b0, e[11:0]};
    endfunction

    always_ff @(posedge clk) begin
        ddr_dout_ready <= 1'b0;
        if (reset) begin
            rd_out <= 1'b0;
            rq     <= 1'b0;
            got0   <= 1'b0;
            got1   <= 1'b0;
            rw0    <= '0;
            rw1    <= '0;
            rr0    <= '0;
            rr1    <= '0;
        end else begin
            if (ddr_rd && !ddr_busy) begin
                rd_out <= 1'b1;
                rq     <= 1'b1;
                got0   <= 1'b0;
                got1   <= 1'b0;
                ridx   <= 14'((ddr_addr - DDR_BASE) >> 1);
                rcnt   <= '0;
            end
            if (ack0) got0 <= 1'b1;
            if (ack1) got1 <= 1'b1;
            if (rq && (got0 || ack0) && (got1 || ack1)) rq <= 1'b0;

            if (rv0) begin rf0[rw0[1:0]] <= rd0; rw0 <= rw0 + 3'd1; end
            if (rv1) begin rf1[rw1[1:0]] <= rd1; rw1 <= rw1 + 3'd1; end

            if (rd_out && rcnt != 4'd8) begin
                if (!rcnt[0] && rw0 != rr0) begin
                    ddr_dout       <= unpack(rf0[rr0[1:0]]);
                    ddr_dout_ready <= 1'b1;
                    rr0            <= rr0 + 3'd1;
                    rcnt           <= rcnt + 4'd1;
                end else if (rcnt[0] && rw1 != rr1) begin
                    ddr_dout       <= unpack(rf1[rr1[1:0]]);
                    ddr_dout_ready <= 1'b1;
                    rr1            <= rr1 + 3'd1;
                    rcnt           <= rcnt + 4'd1;
                end
            end
            if (rd_out && rcnt == 4'd8) rd_out <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // The two chips
    // ------------------------------------------------------------------
    logic rdy0, rdy1;
    assign ready = rdy0 && rdy1;

    pocket_cram u_c0 (
        .clk, .reset, .ready(rdy0),
        .wq_empty(n0 == 6'd0), .wq_idx(wq0_q[61:48]), .wq_data(wq0_q[47:0]), .wq_pop(pop0),
        .rq_valid(rq && !got0), .rq_idx(ridx), .rq_ack(ack0), .rd_valid(rv0), .rd_data(rd0),
        .cr_clk(c0_clk), .cr_a(c0_a), .cr_dq_o(c0_dq_o), .cr_dq_oe(c0_dq_oe), .cr_dq_i(c0_dq_i),
        .cr_wait(c0_wait), .cr_adv_n(c0_adv_n), .cr_cre(c0_cre), .cr_ce_n(c0_ce_n),
        .cr_oe_n(c0_oe_n), .cr_we_n(c0_we_n)
    );
    pocket_cram u_c1 (
        .clk, .reset, .ready(rdy1),
        .wq_empty(n1 == 6'd0), .wq_idx(wq1_q[61:48]), .wq_data(wq1_q[47:0]), .wq_pop(pop1),
        .rq_valid(rq && !got1), .rq_idx(ridx), .rq_ack(ack1), .rd_valid(rv1), .rd_data(rd1),
        .cr_clk(c1_clk), .cr_a(c1_a), .cr_dq_o(c1_dq_o), .cr_dq_oe(c1_dq_oe), .cr_dq_i(c1_dq_i),
        .cr_wait(c1_wait), .cr_adv_n(c1_adv_n), .cr_cre(c1_cre), .cr_ce_n(c1_ce_n),
        .cr_oe_n(c1_oe_n), .cr_we_n(c1_we_n)
    );
endmodule
