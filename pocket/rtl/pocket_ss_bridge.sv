// Analogue Pocket save states / sleep: connects the APF save-state commands
// (core_bridge_cmd 0x00A0 / 0x00A4) and the bridge window at BASE to the
// board's state-word port (shangha3_board.sv, "Save states").
//
// Save: the host asks (savestate_start); the board freezes at a clean point
// and dumps the 68000 (ss_ready). The state words 0..NWORDS-1 are then
// streamed in order into a small FIFO, so a bridge read gets its data at once
// (the bridge samples bridge_rd_data 4 clk_74a cycles after the address and
// strobes bridge_rd afterwards, which pops the word). The host reads the blob
// from the start to the end; after the last word the board resumes.
//
// Load: the host writes the blob to BASE (before or after savestate_load;
// both orders work). The first word stops the 68000 at once; every word goes
// straight into the board's RAMs/registers. Once all NWORDS words are in and
// the load command has come, the board applies the state and resumes.
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).

module pocket_ss_bridge #(
    parameter logic [3:0] BASE_NIB = 4'h4,      // window 0x4000_0000
    parameter int         NWORDS   = 32768      // 128 KB
) (
    // clk_74a side
    input  logic        clk_74a,
    input  logic [31:0] bridge_addr,
    input  logic        bridge_rd,
    input  logic        bridge_wr,
    input  logic [31:0] bridge_wr_data,
    output logic [31:0] rd_data,                // for core_top's read mux (window hit)

    input  logic        savestate_start,
    output logic        savestate_start_ack,
    output logic        savestate_start_busy,
    output logic        savestate_start_ok,
    output logic        savestate_start_err,
    input  logic        savestate_load,
    output logic        savestate_load_ack,
    output logic        savestate_load_busy,
    output logic        savestate_load_ok,
    output logic        savestate_load_err,

    // core side (96 MHz)
    input  logic        clk,
    input  logic        reset,                  // power-up only
    output logic        ss_save,
    output logic        ss_load,
    output logic        ss_commit,
    output logic        ss_release,
    input  logic        ss_ready,
    input  logic        ss_done,
    input  logic        ss_err,
    input  logic        ss_active,
    output logic        ss_rd,
    output logic        ss_wr,
    output logic [14:0] ss_idx,
    output logic [31:0] ss_wdata,
    input  logic [31:0] ss_rdata,
    input  logic        ss_ack
);
    localparam logic [15:0] LAST = 16'(NWORDS - 1);

    // ------------------------------------------------------------------
    // Toggle synchronisers between the two clocks
    // ------------------------------------------------------------------
    logic t_save = 0, t_commit = 0, t_release = 0;       // 74 -> core
    logic t_ready_ok = 0, t_err = 0, t_done = 0;         // core -> 74
    logic [2:0] s_save, s_commit, s_release;             // in core clock
    logic [2:0] s_rdy, s_err, s_done;                    // in clk_74a

    always_ff @(posedge clk) begin
        s_save    <= {s_save[1:0], t_save};
        s_commit  <= {s_commit[1:0], t_commit};
        s_release <= {s_release[1:0], t_release};
    end
    wire c_save    = s_save[2]    ^ s_save[1];
    wire c_commit  = s_commit[2]  ^ s_commit[1];
    wire c_release = s_release[2] ^ s_release[1];

    always_ff @(posedge clk_74a) begin
        s_rdy  <= {s_rdy[1:0], t_ready_ok};
        s_err  <= {s_err[1:0], t_err};
        s_done <= {s_done[1:0], t_done};
    end
    wire a_ready = s_rdy[2]  ^ s_rdy[1];
    wire a_err   = s_err[2]  ^ s_err[1];
    wire a_done  = s_done[2] ^ s_done[1];

    // ------------------------------------------------------------------
    // FIFOs: save words core -> 74, load words 74 -> core
    // ------------------------------------------------------------------
    logic        rf_push, rf_full, rf_pop, rf_empty;
    logic [31:0] rf_din, rf_dout;
    logic        rf_rst_c, rf_rst_a;
    pocket_afifo #(.W(32), .AW(4)) u_rf (
        .wclk(clk), .wrst(rf_rst_c), .push(rf_push), .din(rf_din), .full(rf_full),
        .rclk(clk_74a), .rrst(rf_rst_a), .pop(rf_pop), .dout(rf_dout), .empty(rf_empty)
    );

    logic        wf_push, wf_full, wf_pop, wf_empty;
    logic [46:0] wf_din, wf_dout;
    pocket_afifo #(.W(47), .AW(4)) u_wf (
        .wclk(clk_74a), .wrst(1'b0), .push(wf_push), .din(wf_din), .full(wf_full),
        .rclk(clk), .rrst(reset), .pop(wf_pop), .dout(wf_dout), .empty(wf_empty)
    );

    // ------------------------------------------------------------------
    // clk_74a: commands, reads, writes
    // ------------------------------------------------------------------
    wire in_win = bridge_addr[31:28] == BASE_NIB;
    logic start_q = 0, load_q = 0, rd_q = 0, wr_q = 0;
    logic [15:0] rd_cnt = 0;
    logic        reading = 0;
    logic [27:0] idle_cnt = 0;                  // host stopped reading: resume after ~1.8 s
    logic [3:0]  rst_a_cnt = 0;

    assign rd_data = rf_empty ? 32'd0 : rf_dout;
    assign rf_rst_a = rst_a_cnt != 0;

    initial begin
        savestate_start_ack = 0; savestate_start_busy = 0; savestate_start_ok = 0; savestate_start_err = 0;
        savestate_load_ack  = 0; savestate_load_busy  = 0; savestate_load_ok  = 0; savestate_load_err  = 0;
    end

    always_ff @(posedge clk_74a) begin
        start_q <= savestate_start;
        load_q  <= savestate_load;
        rd_q    <= bridge_rd;
        wr_q    <= bridge_wr;
        rf_pop  <= 1'b0;
        wf_push <= 1'b0;
        savestate_start_ack <= 1'b0;
        savestate_load_ack  <= 1'b0;
        if (rst_a_cnt != 0) rst_a_cnt <= rst_a_cnt - 4'd1;

        // save
        if (savestate_start && !start_q) begin
            savestate_start_ack  <= 1'b1;
            savestate_start_busy <= 1'b1;
            savestate_start_ok   <= 1'b0;
            savestate_start_err  <= 1'b0;
            rd_cnt    <= '0;
            reading   <= 1'b0;
            rst_a_cnt <= 4'd15;          // empty the read FIFO (the core side resets too)
            t_save    <= ~t_save;
        end
        if (a_ready) begin
            savestate_start_busy <= 1'b0;
            savestate_start_ok   <= 1'b1;
            reading              <= 1'b1;
        end
        if (a_err && savestate_start_busy) begin
            savestate_start_busy <= 1'b0;
            savestate_start_err  <= 1'b1;
        end
        // the bridge has taken the word on the bus: next one
        if (reading) idle_cnt <= idle_cnt + 28'd1;
        if (bridge_rd && !rd_q && in_win && reading && !rf_empty) begin
            rf_pop   <= 1'b1;
            rd_cnt   <= rd_cnt + 16'd1;
            idle_cnt <= '0;
            if (rd_cnt == LAST) begin
                reading   <= 1'b0;
                t_release <= ~t_release;
            end
        end else if (reading && &idle_cnt) begin
            reading   <= 1'b0;
            t_release <= ~t_release;
        end

        // load
        if (bridge_wr && !wr_q && in_win && !wf_full) begin
            wf_push <= 1'b1;
            wf_din  <= {bridge_addr[16:2], bridge_wr_data};
        end
        if (savestate_load && !load_q) begin
            savestate_load_ack  <= 1'b1;
            savestate_load_busy <= 1'b1;
            savestate_load_ok   <= 1'b0;
            savestate_load_err  <= 1'b0;
            t_commit <= ~t_commit;
        end
        if (a_done) begin
            savestate_load_busy <= 1'b0;
            savestate_load_ok   <= 1'b1;
        end
        if (a_err && savestate_load_busy) begin
            savestate_load_busy <= 1'b0;
            savestate_load_err  <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Core clock: requests held until the board takes them, the read
    // streamer and the write feeder
    // ------------------------------------------------------------------
    logic        save_pend, load_pend, commit_pend;
    logic [15:0] r_idx, w_cnt;
    logic        r_on, r_wait, w_wait;
    logic        ready_q;
    logic [3:0]  rst_c_cnt;
    assign rf_rst_c = rst_c_cnt != 0;

    always_ff @(posedge clk) begin
        ss_rd      <= 1'b0;
        ss_wr      <= 1'b0;
        ss_commit  <= 1'b0;
        ss_release <= 1'b0;
        rf_push    <= 1'b0;
        wf_pop     <= 1'b0;
        ready_q    <= ss_ready;
        if (rst_c_cnt != 0) rst_c_cnt <= rst_c_cnt - 4'd1;
        if (reset) begin
            save_pend   <= 1'b0;
            load_pend   <= 1'b0;
            commit_pend <= 1'b0;
            r_on   <= 1'b0;
            r_wait <= 1'b0;
            w_wait <= 1'b0;
            w_cnt  <= '0;
            ss_save <= 1'b0;
            ss_load <= 1'b0;
            rst_c_cnt <= 4'd15;
        end else begin
            // save request: held until the board starts (or refuses)
            if (c_save) begin
                save_pend <= 1'b1;
                r_on      <= 1'b0;
                r_wait    <= 1'b0;
                rst_c_cnt <= 4'd15;
            end
            ss_save <= save_pend && !ss_active;
            if (save_pend && (ss_active || ss_err)) save_pend <= 1'b0;
            if (ss_err)  t_err <= ~t_err;
            if (ss_done) t_done <= ~t_done;

            // stream the state words once the board is ready
            if (ss_ready && !ready_q) begin
                r_on      <= 1'b1;
                r_idx     <= '0;
                t_ready_ok <= ~t_ready_ok;
            end
            if (r_on && !r_wait && !rf_full && !rf_rst_c) begin
                ss_rd  <= 1'b1;
                ss_idx <= r_idx[14:0];
                r_wait <= 1'b1;
            end
            if (r_wait && ss_ack) begin
                rf_push <= 1'b1;
                rf_din  <= ss_rdata;
                r_wait  <= 1'b0;
                r_idx   <= r_idx + 16'd1;
                if (r_idx == LAST) r_on <= 1'b0;
            end
            if (c_release) ss_release <= 1'b1;

            // load: the first word starts the load; every word is written
            if (!wf_empty && !w_wait && !wf_pop) begin
                if (!ss_active) begin
                    load_pend <= 1'b1;
                end else if (!ss_ready) begin       // (not during a save read-out)
                    ss_wr    <= 1'b1;
                    ss_idx   <= wf_dout[46:32];
                    ss_wdata <= wf_dout[31:0];
                    w_wait   <= 1'b1;
                end
            end
            if (w_wait && ss_ack) begin
                w_wait <= 1'b0;
                wf_pop <= 1'b1;
                w_cnt  <= w_cnt + 16'd1;
            end
            ss_load <= load_pend && !ss_active;
            if (load_pend && ss_active) load_pend <= 1'b0;

            if (c_commit) commit_pend <= 1'b1;
            if (commit_pend && w_cnt == 16'(NWORDS) && wf_empty && !w_wait) begin
                ss_commit   <= 1'b1;
                commit_pend <= 1'b0;
                w_cnt       <= '0;
            end
        end
    end
endmodule
