// Analogue Pocket cellular RAM (AS1C8M16PL PSRAM) controller: synchronous
// burst reads and writes of "entries" of three 16-bit words (48 bits, four
// 12-bit pixels), for the display frame buffer.
//
// Clocking: everything runs on the 96 MHz core clock. The PSRAM clock is a
// register that toggles every core clock (48 MHz). With R_k the k-th rising
// edge of the PSRAM clock (produced by the core-clock edge "A_k"):
//   - inputs (WAIT, DQ) are registered at the A edges; the A_(k+1) sample holds
//     what the chip drove after R_k (about 10 ns of margin either side at
//     48 MHz);
//   - the state machine and every output pin register update at the B edges
//     (the core-clock edges where the PSRAM clock falls), so outputs are
//     stable half a PSRAM cycle before the next rising edge.
// A decision at B_k therefore uses what the chip drove after R_(k-1) and
// changes what it sees at R_(k+1). This is the same cycle relationship as
// jtframe's Pocket PSRAM controller (jtframe_lfbuf_ctrl.v, proven on hardware),
// whose WAIT handling it follows: the chip is configured for variable latency
// with WAIT active low and asserted during the delay; WAIT seen high after R_j
// means the chip transfers a word at R_(j+1).
//
// The chip is used in its own address space; this core needs 32256 words per
// chip. Bursts are short (at most MAXE entries), far below the 4 us CE# low
// limit, so the chip's own refresh keeps working.
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).

module pocket_cram #(
    parameter int MAXE = 24                 // entries per write burst (72 words)
) (
    input  logic        clk,                // 96 MHz
    input  logic        reset,
    output logic        ready,              // configured

    // write queue (show-ahead FIFO owned by the caller)
    input  logic        wq_empty,
    input  logic [13:0] wq_idx,             // entry index (word address = 3 x idx)
    input  logic [47:0] wq_data,
    output logic        wq_pop,

    // read request: 4 consecutive entries starting at rq_idx
    input  logic        rq_valid,
    input  logic [13:0] rq_idx,
    output logic        rq_ack,
    output logic        rd_valid,
    output logic [47:0] rd_data,

    // chip pins
    output logic        cr_clk,
    output logic [21:16] cr_a,
    output logic [15:0] cr_dq_o,
    output logic        cr_dq_oe,
    input  logic [15:0] cr_dq_i,
    input  logic        cr_wait,
    output logic        cr_adv_n,
    output logic        cr_cre,
    output logic        cr_ce_n,
    output logic        cr_oe_n,
    output logic        cr_we_n
);
    // Bus configuration register (written through CRE at start-up):
    // synchronous burst, variable latency, latency code 3, WAIT active low and
    // asserted during the delay, default drive strength, no wrap, continuous.
    localparam logic [21:0] BCR = {
        2'd0,   // [21:20] reserved
        2'd2,   // [19:18] register select: BCR
        2'd0,   // [17:16] reserved
        1'b0,   // [15]    0 = synchronous burst mode
        1'b0,   // [14]    0 = variable latency
        3'd3,   // [13:11] latency counter
        1'b0,   // [10]    WAIT polarity: active low
        1'b0,   // [9]     reserved
        1'b0,   // [8]     WAIT asserted during the delay
        2'd0,   // [7:6]   reserved
        2'd1,   // [5:4]   drive strength
        1'b1,   // [3]     no burst wrap
        3'd7    // [2:0]   continuous burst
    };

    // ------------------------------------------------------------------
    // PSRAM clock and input sampling
    // ------------------------------------------------------------------
    logic cc = 1'b0;
    always_ff @(posedge clk) cc <= ~cc;
    assign cr_clk = cc;
    wire ce_a = !cc;                        // this edge: PSRAM clock rises
    wire ce_b =  cc;                        // this edge: PSRAM clock falls

    logic        wait_q;
    logic [15:0] dqi_q;
    always_ff @(posedge clk) if (ce_a) begin
        wait_q <= cr_wait;
        dqi_q  <= cr_dq_i;
    end

    // The write queue's head, registered at the A edges (timing: the FIFO's
    // read path plus the next-entry compare didn't fit in one 96 MHz clock on
    // the Pocket). The copy taken right after a pop still shows the popped
    // entry, but the state machine never looks at the queue in the decision
    // after a pop: entries are 3 words long, so the next look is at least 3
    // decisions later.
    logic        q_empty, q_next;
    logic [13:0] q_idx;
    logic [47:0] q_data;
    logic [13:0] widx;              // write: index of the entry being written
    always_ff @(posedge clk) if (ce_a) begin
        q_empty <= wq_empty;
        q_idx   <= wq_idx;
        q_data  <= wq_data;
        q_next  <= !wq_empty && wq_idx == widx + 14'd1;
    end

    // ------------------------------------------------------------------
    // State machine (B edges)
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_PWR, S_CFG, S_IDLE, S_RADV, S_RDAT, S_WADV, S_WDAT
    } st_t;
    st_t         st;
    logic [14:0] cnt;               // power-up wait / config step
    logic        wait1;
    logic [21:0] addr;
    logic [3:0]  rn;                // read: words received (0..11)
    logic [31:0] rasm;              // read: first two words of the entry
    logic [1:0]  wn;                // write: word of the entry on the bus (0..2)
    logic [47:0] wcur;              // write: entry being written
    logic [5:0]  ecnt;              // write: entries in this burst

    always_ff @(posedge clk) begin
        wq_pop   <= 1'b0;
        rq_ack   <= 1'b0;
        rd_valid <= 1'b0;
        if (reset) begin
            st       <= S_PWR;
            cnt      <= '0;
            ready    <= 1'b0;
            cr_ce_n  <= 1'b1;
            cr_adv_n <= 1'b1;
            cr_cre   <= 1'b0;
            cr_oe_n  <= 1'b1;
            cr_we_n  <= 1'b1;
            cr_dq_oe <= 1'b0;
            cr_dq_o  <= '0;
            cr_a     <= '0;
            wait1    <= 1'b0;
        end else if (ce_b) begin
            wait1 <= 1'b0;
            case (st)
                // 200 us after reset (the chip is powered long before this
                // core loads; this is only a margin)
                S_PWR: begin
                    cnt <= cnt + 15'd1;
                    if (cnt == 15'd9600) begin
                        cnt <= '0;
                        st  <= S_CFG;
                    end
                end

                // asynchronous configuration register write (CRE)
                S_CFG: begin
                    cnt <= cnt + 15'd1;
                    case (cnt[3:0])
                        4'd0: begin                      // latch register address
                            cr_ce_n  <= 1'b0;
                            cr_cre   <= 1'b1;
                            cr_adv_n <= 1'b0;
                            {cr_a, cr_dq_o} <= BCR;
                            cr_dq_oe <= 1'b1;
                        end
                        4'd1: cr_adv_n <= 1'b1;          // CRE still high at ADV# rising
                        4'd2: cr_cre   <= 1'b0;
                        4'd3: cr_we_n  <= 1'b0;          // write pulse: 3 cycles = 62.5 ns
                        4'd6: begin
                            cr_we_n  <= 1'b1;
                            cr_ce_n  <= 1'b1;
                            cr_dq_oe <= 1'b0;
                        end
                        4'd15: begin
                            st    <= S_IDLE;
                            ready <= 1'b1;
                        end
                        default: ;
                    endcase
                end

                S_IDLE: begin
                    cr_ce_n  <= 1'b1;
                    cr_adv_n <= 1'b1;
                    cr_oe_n  <= 1'b1;
                    cr_we_n  <= 1'b1;
                    cr_dq_oe <= 1'b0;
                    if (rq_valid) begin
                        addr    <= 22'(rq_idx) * 22'd3;
                        rq_ack  <= 1'b1;
                        cr_ce_n <= 1'b0;
                        st      <= S_RADV;
                    end else if (!q_empty) begin
                        addr    <= 22'(q_idx) * 22'd3;
                        cr_ce_n <= 1'b0;
                        st      <= S_WADV;
                    end
                end

                // ---------------- reads ----------------
                S_RADV: begin
                    cr_adv_n <= 1'b0;
                    {cr_a, cr_dq_o} <= addr;
                    cr_dq_oe <= 1'b1;
                    cr_we_n  <= 1'b1;
                    wait1    <= 1'b1;
                    rn       <= '0;
                    st       <= S_RDAT;
                end
                S_RDAT: begin
                    cr_adv_n <= 1'b1;
                    cr_dq_oe <= 1'b0;
                    cr_oe_n  <= 1'b0;
                    if (wait_q && !wait1) begin
                        rn <= rn + 4'd1;
                        case (rn)
                            4'd0, 4'd3, 4'd6, 4'd9:  rasm[15:0]  <= dqi_q;
                            4'd1, 4'd4, 4'd7, 4'd10: rasm[31:16] <= dqi_q;
                            default: begin
                                rd_valid <= 1'b1;
                                rd_data  <= {dqi_q, rasm};
                            end
                        endcase
                        if (rn == 4'd11) begin
                            cr_ce_n <= 1'b1;
                            cr_oe_n <= 1'b1;
                            st      <= S_IDLE;
                        end
                    end
                end

                // ---------------- writes ----------------
                S_WADV: begin
                    cr_adv_n <= 1'b0;
                    {cr_a, cr_dq_o} <= addr;
                    cr_dq_oe <= 1'b1;
                    cr_we_n  <= 1'b0;
                    wait1    <= 1'b1;
                    wcur     <= q_data;
                    widx     <= q_idx;
                    wq_pop   <= 1'b1;
                    wn       <= 2'd0;
                    ecnt     <= 6'd1;
                    st       <= S_WDAT;
                end
                S_WDAT: begin
                    cr_adv_n <= 1'b1;
                    cr_we_n  <= 1'b0;
                    if (wait1) begin
                        cr_dq_o <= wcur[15:0];           // word 0 from the next edge on
                    end else if (wait_q) begin
                        // the word on the bus has been taken: present the next one
                        if (wn != 2'd2) begin
                            wn      <= wn + 2'd1;
                            cr_dq_o <= (wn == 2'd0) ? wcur[31:16] : wcur[47:32];
                        end else if (q_next && ecnt != 6'(MAXE)) begin
                            wn      <= 2'd0;
                            wcur    <= q_data;
                            widx    <= q_idx;
                            wq_pop  <= 1'b1;
                            ecnt    <= ecnt + 6'd1;
                            cr_dq_o <= q_data[15:0];
                        end else begin
                            cr_ce_n  <= 1'b1;
                            cr_we_n  <= 1'b1;
                            cr_dq_oe <= 1'b0;
                            st       <= S_IDLE;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
