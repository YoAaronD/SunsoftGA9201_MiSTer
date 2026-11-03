// SunsoftGA9201 for Analogue Pocket - top level (instantiated by apf/apf_top.v)
`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
);

// ============================================================================
// SunsoftGA9201 for Analogue Pocket: Shanghai III, Hebereke no Popoon, Blocken.
// The game hardware (rtl/, ext/) is shared with the MiSTer core; this file
// replaces the MiSTer framework (sys/, SunsoftGA9201.sv). Port list above from
// Analogue's openFPGA core template.
//
// Clocks (pocket_pll, from clk_74a):
//   clk_sys 96 MHz   core (one clock with enables, as on the MiSTer)
//   clk_pix 8 MHz    video to the scaler (= clk_sys / 12, same VCO)
//   clk_pix90        8 MHz, 90 degrees
// Memories: SDRAM (dram_*) holds the ROMs as on the MiSTer; the two cellular
// RAM chips hold the display frame buffer (the MiSTer uses DDR3 for it);
// the SRAM is unused.
//
// Bridge addresses written by the instance JSON / Pocket menu (interact.json):
//   0x00000000-0x0FFFFFFF  ROM data slot (the MiSTer's ioctl index 0 stream)
//   0x20000000  game: 0 Shanghai III, 1 Hebereke no Popoon, 2 Blocken
//   0x20000004  DIP switches: [7:0] SW1, [15:8] SW2
//   0x20000100  reset (any write)
//   0x20000104  service mode (bit 0)
//   0x20000108  OKI (drums/FX) balance, 0 = PCB (as the MiSTer OSD option)
//   0x2000010C  frame buffer: 0 = cellular RAM (tear-free), 1 = direct scan-out
//   0x20000110  pause while the Pocket menu is open: 0 = yes, 1 = no
//
// SunsoftGA9201 Analogue Pocket port. GPL-3.0-or-later (see LICENSE).
// ============================================================================

// ---------------------------------------------------------------------------
// unused interfaces
// ---------------------------------------------------------------------------
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

assign bridge_endian_little = 0;

assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;
assign cart_tran_pin31 = 1'bz;
assign cart_tran_pin31_dir = 1'b0;

assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;

// ---------------------------------------------------------------------------
// Clocks
// ---------------------------------------------------------------------------
wire clk_sys, clk_pix, clk_pix90, pll_locked;

pocket_pll u_pll (
    .refclk   ( clk_74a    ),
    .rst      ( 1'b0       ),
    .outclk_0 ( clk_sys    ),
    .outclk_1 ( clk_pix    ),
    .outclk_2 ( clk_pix90  ),
    .locked   ( pll_locked )
);

wire pll_locked_74;
synch_3 s_lock74(pll_locked, pll_locked_74, clk_74a);

reg [2:0] lock_sys = 3'b000;
always @(posedge clk_sys) lock_sys <= {lock_sys[1:0], pll_locked};
wire sys_init = !lock_sys[2];          // power-up reset of the core clock domain

// ---------------------------------------------------------------------------
// APF host commands (clk_74a)
// ---------------------------------------------------------------------------
wire        reset_n;
wire [31:0] cmd_bridge_rd_data;

wire        status_boot_done  = pll_locked_74;
wire        status_setup_done = pll_locked_74;
wire        status_running    = reset_n;

wire        dataslot_requestread;
wire [15:0] dataslot_requestread_id;
wire        dataslot_requestread_ack = 1;
wire        dataslot_requestread_ok  = 1;
wire        dataslot_requestwrite;
wire [15:0] dataslot_requestwrite_id;
wire [31:0] dataslot_requestwrite_size;
wire        dataslot_requestwrite_ack = 1;
wire        dataslot_requestwrite_ok  = 1;
wire        dataslot_update;
wire [15:0] dataslot_update_id;
wire [31:0] dataslot_update_size;
wire        dataslot_allcomplete;

wire [31:0] rtc_epoch_seconds;
wire [31:0] rtc_date_bcd;
wire [31:0] rtc_time_bcd;
wire        rtc_valid;

wire        savestate_supported = 0;
wire [31:0] savestate_addr = 0;
wire [31:0] savestate_size = 0;
wire [31:0] savestate_maxloadsize = 0;
wire        savestate_start;
wire        savestate_start_ack = 0;
wire        savestate_start_busy = 0;
wire        savestate_start_ok = 0;
wire        savestate_start_err = 0;
wire        savestate_load;
wire        savestate_load_ack = 0;
wire        savestate_load_busy = 0;
wire        savestate_load_ok = 0;
wire        savestate_load_err = 0;

wire        osnotify_inmenu;

reg         target_dataslot_read = 0;
reg         target_dataslot_write = 0;
reg         target_dataslot_getfile = 0;
reg         target_dataslot_openfile = 0;
wire        target_dataslot_ack;
wire        target_dataslot_done;
wire [2:0]  target_dataslot_err;
reg  [15:0] target_dataslot_id = 0;
reg  [31:0] target_dataslot_slotoffset = 0;
reg  [31:0] target_dataslot_bridgeaddr = 0;
reg  [31:0] target_dataslot_length = 0;
wire [31:0] target_buffer_param_struct;
wire [31:0] target_buffer_resp_struct;

wire [9:0]  datatable_addr;
wire        datatable_wren;
wire [31:0] datatable_data;
wire [31:0] datatable_q;

core_bridge_cmd icb (
    .clk                        ( clk_74a ),
    .reset_n                    ( reset_n ),
    .bridge_endian_little       ( bridge_endian_little ),
    .bridge_addr                ( bridge_addr ),
    .bridge_rd                  ( bridge_rd ),
    .bridge_rd_data             ( cmd_bridge_rd_data ),
    .bridge_wr                  ( bridge_wr ),
    .bridge_wr_data             ( bridge_wr_data ),
    .status_boot_done           ( status_boot_done ),
    .status_setup_done          ( status_setup_done ),
    .status_running             ( status_running ),
    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),
    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),
    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    .dataslot_allcomplete       ( dataslot_allcomplete ),
    .rtc_epoch_seconds          ( rtc_epoch_seconds ),
    .rtc_date_bcd               ( rtc_date_bcd ),
    .rtc_time_bcd               ( rtc_time_bcd ),
    .rtc_valid                  ( rtc_valid ),
    .savestate_supported        ( savestate_supported ),
    .savestate_addr             ( savestate_addr ),
    .savestate_size             ( savestate_size ),
    .savestate_maxloadsize      ( savestate_maxloadsize ),
    .savestate_start            ( savestate_start ),
    .savestate_start_ack        ( savestate_start_ack ),
    .savestate_start_busy       ( savestate_start_busy ),
    .savestate_start_ok         ( savestate_start_ok ),
    .savestate_start_err        ( savestate_start_err ),
    .savestate_load             ( savestate_load ),
    .savestate_load_ack         ( savestate_load_ack ),
    .savestate_load_busy        ( savestate_load_busy ),
    .savestate_load_ok          ( savestate_load_ok ),
    .savestate_load_err         ( savestate_load_err ),
    .osnotify_inmenu            ( osnotify_inmenu ),
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),
    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),
    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    .datatable_addr             ( datatable_addr ),
    .datatable_wren             ( datatable_wren ),
    .datatable_data             ( datatable_data ),
    .datatable_q                ( datatable_q )
);

// ---------------------------------------------------------------------------
// Settings registers (clk_74a), written by the instance JSON and the menu
// ---------------------------------------------------------------------------
reg  [1:0]  cfg_game    = 2'd0;
reg  [15:0] cfg_dip     = 16'hBFFF;      // Shanghai III defaults (SW1 FF, SW2 BF)
reg         cfg_service = 1'b0;
reg  [2:0]  cfg_oki     = 3'd0;
reg         cfg_direct  = 1'b0;
reg         cfg_nopause = 1'b0;
reg  [7:0]  rst_req     = 8'd0;          // reset request from the menu (stretched)

always @(posedge clk_74a) begin
    if (rst_req != 8'd0) rst_req <= rst_req - 8'd1;
    if (bridge_wr && bridge_addr[31:28] == 4'h2) begin
        case (bridge_addr[11:0])
            12'h000: cfg_game    <= bridge_wr_data[1:0];
            12'h004: cfg_dip     <= bridge_wr_data[15:0];
            12'h100: rst_req     <= 8'hFF;
            12'h104: cfg_service <= bridge_wr_data[0];
            12'h108: cfg_oki     <= bridge_wr_data[2:0];
            12'h10C: cfg_direct  <= bridge_wr_data[0];
            12'h110: cfg_nopause <= bridge_wr_data[0];
            default: ;
        endcase
    end
end

always @(*) begin
    casex (bridge_addr)
        32'h2xxxxxxx: begin
            case (bridge_addr[11:0])
                12'h000: bridge_rd_data = {30'd0, cfg_game};
                12'h004: bridge_rd_data = {16'd0, cfg_dip};
                12'h104: bridge_rd_data = {31'd0, cfg_service};
                12'h108: bridge_rd_data = {29'd0, cfg_oki};
                12'h10C: bridge_rd_data = {31'd0, cfg_direct};
                12'h110: bridge_rd_data = {31'd0, cfg_nopause};
                default: bridge_rd_data = 32'd0;
            endcase
        end
        32'hF8xxxxxx: bridge_rd_data = cmd_bridge_rd_data;
        default:      bridge_rd_data = 32'd0;
    endcase
end

// ---------------------------------------------------------------------------
// clk_74a -> clk_sys. The settings only change while the game is held in
// reset (instance JSON) or are single bits (menu); two flops are enough.
// ---------------------------------------------------------------------------
reg [1:0]  game_s1, game_s;
reg [15:0] dip_s1, dip_s;
reg [2:0]  oki_s1, oki_s;
reg [5:0]  bits_s1, bits_s;
reg [31:0] key1_s1, key1_s, key2_s1, key2_s;
always @(posedge clk_sys) begin
    {game_s, game_s1} <= {game_s1, cfg_game};
    {dip_s, dip_s1}   <= {dip_s1, cfg_dip};
    {oki_s, oki_s1}   <= {oki_s1, cfg_oki};
    {bits_s, bits_s1} <= {bits_s1, {reset_n, rst_req != 8'd0, cfg_service, cfg_direct, cfg_nopause, osnotify_inmenu}};
    {key1_s, key1_s1} <= {key1_s1, cont1_key};
    {key2_s, key2_s1} <= {key2_s1, cont2_key};
end
wire run_s     = bits_s[5];
wire menu_rst  = bits_s[4];
wire service_s = bits_s[3];
wire direct_s  = bits_s[2];
wire nopause_s = bits_s[1];
wire inmenu_s  = bits_s[0];

// ---------------------------------------------------------------------------
// Controls (MiSTer joystick order: R L D U B1 B2 B3 Start Coin Service)
// ---------------------------------------------------------------------------
function [9:0] joy(input [31:0] k);
    joy = {k[9], k[14], k[15], k[6], k[5], k[4], k[0], k[1], k[2], k[3]};
endfunction
wire [9:0] joy1 = joy(key1_s);
wire [9:0] joy2 = joy(key2_s);

wire [15:0] in_inputs = ~{1'b0, joy2[6:0], 1'b0, joy1[6:0]};
wire  [6:0] in_system = ~{1'b0, service_s, joy2[7], joy1[7], joy1[9] | joy2[9], joy2[8], joy1[8]};

// ---------------------------------------------------------------------------
// ROM loading
// ---------------------------------------------------------------------------
wire        ioctl_download, ioctl_wr, ioctl_wait, load_overflow;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;

pocket_loader u_loader (
    .clk_74a        ( clk_74a ),
    .bridge_wr      ( bridge_wr ),
    .bridge_addr    ( bridge_addr ),
    .bridge_wr_data ( bridge_wr_data ),
    .running        ( reset_n ),
    .clk            ( clk_sys ),
    .reset          ( sys_init ),
    .ioctl_download ( ioctl_download ),
    .ioctl_wr       ( ioctl_wr ),
    .ioctl_addr     ( ioctl_addr ),
    .ioctl_dout     ( ioctl_dout ),
    .ioctl_wait     ( ioctl_wait ),
    .overflow       ( load_overflow )
);

// ---------------------------------------------------------------------------
// The game
// ---------------------------------------------------------------------------
wire        ce_pix, hs, vs, hbl, vbl, vbl_next;
wire  [7:0] r, g, b;
wire signed [15:0] snd;

wire        ddr_busy, ddr_dout_ready, ddr_rd, ddr_we;
wire  [7:0] ddr_burstcnt, ddr_be;
wire [28:0] ddr_addr;
wire [63:0] ddr_dout, ddr_din;

wire        sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dqml, sd_dqmh;

shangha3_top core (
    .clk            ( clk_sys ),
    .reset          ( !run_s || menu_rst ),
    .sdram_init     ( sys_init ),
    .pause          ( inmenu_s && !nopause_s ),
    .snd_balance    ( oki_s ),
    .game_id        ( game_s ),
    .direct_scan    ( direct_s ),

    .ioctl_download ( ioctl_download ),
    .ioctl_index    ( 16'd0 ),
    .ioctl_wr       ( ioctl_wr ),
    .ioctl_addr     ( ioctl_addr ),
    .ioctl_dout     ( ioctl_dout ),
    .ioctl_wait     ( ioctl_wait ),

    .in_inputs      ( in_inputs ),
    .in_system      ( in_system ),
    .dsw1           ( dip_s[7:0] ),
    .dsw2           ( dip_s[15:8] ),

    .ce_pix         ( ce_pix ),
    .hsync          ( hs ),
    .vsync          ( vs ),
    .hblank         ( hbl ),
    .vblank         ( vbl ),
    .vblank_next    ( vbl_next ),
    .red            ( r ),
    .green          ( g ),
    .blue           ( b ),

    .ddr_busy       ( ddr_busy ),
    .ddr_burstcnt   ( ddr_burstcnt ),
    .ddr_addr       ( ddr_addr ),
    .ddr_dout       ( ddr_dout ),
    .ddr_dout_ready ( ddr_dout_ready ),
    .ddr_rd         ( ddr_rd ),
    .ddr_din        ( ddr_din ),
    .ddr_be         ( ddr_be ),
    .ddr_we         ( ddr_we ),
    .rot_we         ( 1'b0 ),
    .rot_addr       ( 29'd0 ),
    .rot_din        ( 64'd0 ),
    .rot_be         ( 8'd0 ),

    .snd            ( snd ),

    .SDRAM_CLK      ( dram_clk ),
    .SDRAM_CKE      ( dram_cke ),
    .SDRAM_A        ( dram_a ),
    .SDRAM_BA       ( dram_ba ),
    .SDRAM_DQ       ( dram_dq ),
    .SDRAM_DQML     ( sd_dqml ),
    .SDRAM_DQMH     ( sd_dqmh ),
    .SDRAM_nCS      ( sd_cs_n ),
    .SDRAM_nCAS     ( sd_cas_n ),
    .SDRAM_nRAS     ( sd_ras_n ),
    .SDRAM_nWE      ( sd_we_n )
);

// The Pocket's SDRAM has no chip select. The controller (rtl/sdram.sv) can
// drive two chips and deselects for the second one (e.g. its double refresh);
// a deselected cycle must be a NOP here.
assign dram_ras_n = sd_ras_n | sd_cs_n;
assign dram_cas_n = sd_cas_n | sd_cs_n;
assign dram_we_n  = sd_we_n  | sd_cs_n;
assign dram_dqm   = {sd_dqmh, sd_dqml};

// ---------------------------------------------------------------------------
// Display frame buffer in the two cellular RAM chips
// ---------------------------------------------------------------------------
wire        c0_dq_oe, c1_dq_oe, c0_ce_n, c1_ce_n;
wire [15:0] c0_dq_o, c1_dq_o;

pocket_fb u_fb (
    .clk            ( clk_sys ),
    .reset          ( sys_init ),
    .ready          ( ),
    .ddr_busy       ( ddr_busy ),
    .ddr_burstcnt   ( ddr_burstcnt ),
    .ddr_addr       ( ddr_addr ),
    .ddr_dout       ( ddr_dout ),
    .ddr_dout_ready ( ddr_dout_ready ),
    .ddr_rd         ( ddr_rd ),
    .ddr_din        ( ddr_din ),
    .ddr_be         ( ddr_be ),
    .ddr_we         ( ddr_we ),

    .c0_clk   ( cram0_clk ),   .c0_a     ( cram0_a ),
    .c0_dq_o  ( c0_dq_o ),     .c0_dq_oe ( c0_dq_oe ),  .c0_dq_i ( cram0_dq ),
    .c0_wait  ( cram0_wait ),  .c0_adv_n ( cram0_adv_n ), .c0_cre ( cram0_cre ),
    .c0_ce_n  ( c0_ce_n ),     .c0_oe_n  ( cram0_oe_n ),  .c0_we_n ( cram0_we_n ),

    .c1_clk   ( cram1_clk ),   .c1_a     ( cram1_a ),
    .c1_dq_o  ( c1_dq_o ),     .c1_dq_oe ( c1_dq_oe ),  .c1_dq_i ( cram1_dq ),
    .c1_wait  ( cram1_wait ),  .c1_adv_n ( cram1_adv_n ), .c1_cre ( cram1_cre ),
    .c1_ce_n  ( c1_ce_n ),     .c1_oe_n  ( cram1_oe_n ),  .c1_we_n ( cram1_we_n )
);

assign cram0_dq    = c0_dq_oe ? c0_dq_o : 16'hZZZZ;
assign cram0_ce0_n = c0_ce_n;
assign cram0_ce1_n = 1'b1;
assign cram0_ub_n  = 1'b0;
assign cram0_lb_n  = 1'b0;
assign cram1_dq    = c1_dq_oe ? c1_dq_o : 16'hZZZZ;
assign cram1_ce0_n = c1_ce_n;
assign cram1_ce1_n = 1'b1;
assign cram1_ub_n  = 1'b0;
assign cram1_lb_n  = 1'b0;

// ---------------------------------------------------------------------------
// Video and audio
// ---------------------------------------------------------------------------
assign video_rgb_clock    = clk_pix;
assign video_rgb_clock_90 = clk_pix90;

pocket_video u_video (
    .clk_pix    ( clk_pix ),
    .red        ( r ),
    .green      ( g ),
    .blue       ( b ),
    .hblank     ( hbl ),
    .vblank     ( vbl ),
    .hsync      ( hs ),
    .vsync      ( vs ),
    .video_rgb  ( video_rgb ),
    .video_de   ( video_de ),
    .video_skip ( video_skip ),
    .video_vs   ( video_vs ),
    .video_hs   ( video_hs )
);

pocket_audio u_audio (
    .clk        ( clk_sys ),
    .snd        ( snd ),
    .clk_74a    ( clk_74a ),
    .audio_mclk ( audio_mclk ),
    .audio_lrck ( audio_lrck ),
    .audio_dac  ( audio_dac )
);

endmodule
`default_nettype wire
