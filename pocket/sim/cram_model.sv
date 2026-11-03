// Behavioural model of one Pocket cellular RAM chip (AS1C8M16PL) in the mode
// pocket_cram.sv programs: synchronous burst, variable latency, WAIT active
// low and asserted during the delay. Simulation only.
//
// Per rising edge of the chip clock:
//   - an edge with CE# and ADV# low latches the address (CRE high: a
//     configuration register; the BCR value is checked when WE# pulses);
//   - write burst: the word on DQ is stored at an edge if WAIT was high after
//     the previous edge;
//   - read burst: data driven after an edge is valid when WAIT is high with it.
// The initial latency is LAT cycles, doubled at random (refresh collision);
// a burst crossing a 128-word row stalls for LAT cycles. Outside CE# the WAIT
// and DQ outputs are random, so the controller must not rely on them.

module cram_model #(
    parameter int LAT  = 3,
    parameter int SEED = 1
) (
    input  logic        clk,
    input  logic [21:16] a,
    input  logic [15:0] dq_i,         // controller -> chip
    input  logic        dq_oe,        // controller drives DQ
    output logic [15:0] dq_o,         // chip -> controller
    output logic        wait_o,
    input  logic        adv_n, cre, ce_n, oe_n, we_n,
    output int          errors,
    output int          words_w,
    output int          words_r,
    output logic        bcr_ok
);
    localparam logic [21:0] BCR_EXPECT = 22'h08181F;

    logic [15:0] mem [0:65535];
    int          rng;
    logic        cfg_pend;
    logic [21:0] cfg_addr;
    logic        burst, wr;
    logic [21:0] ptr;
    int          lat;

    function automatic int rnd();
        rng = rng * 1103515245 + 12345;
        return (rng >>> 8) & 32'h7fffff;
    endfunction

    initial begin
        rng = SEED; errors = 0; words_w = 0; words_r = 0; bcr_ok = 0;
        burst = 0; cfg_pend = 0; wait_o = 0; dq_o = 0; lat = 0;
        for (int i = 0; i < 65536; i++) mem[i] = 16'hdead;
    end

    always @(posedge clk) begin
        if (ce_n) begin
            burst  <= 0;
            wait_o <= rnd() & 1;
            dq_o   <= 16'(rnd());
        end else if (!adv_n) begin
            if (!dq_oe) begin $display("cram_model: ADV# low without an address on DQ"); errors <= errors + 1; end
            if (cre) begin
                cfg_addr <= {a, dq_i};
                cfg_pend <= 1;
                burst    <= 0;
            end else begin
                if (!bcr_ok) begin $display("cram_model: burst before the BCR was written"); errors <= errors + 1; end
                burst  <= 1;
                wr     <= !we_n;
                ptr    <= {a, dq_i};
                lat    <= ((rnd() & 7) == 0) ? 2 * LAT : LAT;
                wait_o <= 0;
            end
        end else if (cfg_pend) begin
            if (!we_n) begin
                bcr_ok   <= ({cfg_addr} == BCR_EXPECT);
                if (cfg_addr != BCR_EXPECT) begin
                    $display("cram_model: configuration register written as %06X", cfg_addr);
                    errors <= errors + 1;
                end
                cfg_pend <= 0;
            end
        end else if (burst) begin
            if (wr) begin
                logic [21:0] p;
                p = ptr;
                if (wait_o) begin                       // transfer at this edge
                    if (!dq_oe) begin $display("cram_model: write word not driven"); errors <= errors + 1; end
                    if (we_n)   begin $display("cram_model: WE# high during a write burst"); errors <= errors + 1; end
                    mem[p[15:0]] <= dq_i;
                    words_w <= words_w + 1;
                    p = p + 1;
                    ptr <= p;
                end
                if (lat > 1) begin
                    lat    <= lat - 1;
                    wait_o <= 0;
                end else if (lat == 1) begin
                    lat    <= 0;
                    wait_o <= 1;
                end else if (wait_o && p[6:0] == 7'd0) begin
                    lat    <= LAT - 1;                  // row crossing
                    wait_o <= 0;
                end else begin
                    wait_o <= 1;
                end
            end else begin
                if (lat > 1) begin
                    lat    <= lat - 1;
                    wait_o <= 0;
                    dq_o   <= 16'(rnd());
                end else if (lat == 1 || !(wait_o && ptr[6:0] == 7'd0)) begin
                    if (oe_n) begin $display("cram_model: read data with OE# high"); errors <= errors + 1; end
                    lat     <= 0;
                    wait_o  <= 1;
                    dq_o    <= mem[ptr[15:0]];
                    ptr     <= ptr + 1;
                    words_r <= words_r + 1;
                end else begin
                    lat    <= LAT - 1;                  // row crossing
                    wait_o <= 0;
                    dq_o   <= 16'(rnd());
                end
            end
        end
    end
endmodule
