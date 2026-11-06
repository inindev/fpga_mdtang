// Sychronized upscaler to HDMI
// nand2mario, 2024.10
//
// This module takes RGB pixel input, buffers 16 lines of the video in BRAM, 
// then upscales and output the video in 720p HDMI format.
// The video aspect ratio is 4:3, with the video centered on the screen.
//
// This is different from framebuffer.sv in that it requires the input video
// to be synchronized to HDMI. This allows the module use much less BRAM space
// compared to a full framebuffer.
module framebuffer #(
    parameter WIDTH = 320,          // max frame width (<=1280)
    parameter HEIGHT = 240,         // max frame height (<=720)
    parameter COLOR_BITS = 4,       // bits per RGB color channel
    parameter FULL_FRAME = 0        // 1: also keep a full frame, shown dimmed under the menu
)(
	input clk,                      // megadrive clock
	input resetn,
	input clk_pixel,                // 74.25Mhz pixel clock
	input clk_5x_pixel,             // 5x pixel clock

    // video signals
    input ce_pix,                   // pixel strobe
    input [COLOR_BITS-1:0] r,       // pixel color
    input [COLOR_BITS-1:0] g,
    input [COLOR_BITS-1:0] b,
    input [$clog2(WIDTH)-1:0] x,    // pixel position
    input [$clog2(HEIGHT)-1:0] y,
    input [10:0] width,             // frame width
    input [9:0] height,             // frame height

    output reg pause_core,          // sync mechanism: input video should be a bit faster (e.g. 0.x%)
                                    // than HDMI. It should wait after line 0 is rendered
                                    // and wait for sync_line1 to continue rendering.

    // overlay from iosys
    input overlay,
    input osd_strip,                // with overlay: only the strip (volume bar), over the running game
    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color,     // BGR5

    input [15:0] audio_left,        // audio sample
    input [15:0] audio_right,
    input [3:0] volume,       // master volume 0-10 from iosys (hdmi.sv brings it into the pixel clock)

	// HDMI output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

localparam CLKFRQ = 74250;

// video stuff
wire [10:0] cx /* xsynthesis syn_keep=1 */;
wire [9:0] cy  /* xsynthesis syn_keep=1 */;

//
// BRAM frame buffer
//
localparam FB_DEPTH = WIDTH * 32;           // buffer 16 lines
localparam COLOR_WIDTH = COLOR_BITS * 3;
localparam FB_AWIDTH = $clog2(FB_DEPTH);
reg [COLOR_WIDTH-1:0] mem [0:FB_DEPTH-1];
reg [FB_AWIDTH-1:0] mem_portA_addr;
reg mem_portA_we;

wire [FB_AWIDTH-1:0] mem_portB_addr;
reg [COLOR_WIDTH-1:0] mem_portB_rdata;

// BRAM port A read/write
reg ce_pix_r, hblank_r;
assign mem_portA_addr = y[4:0] * WIDTH + x;
always @(posedge clk) begin
    ce_pix_r <= ce_pix;
    if (ce_pix & ~ce_pix_r) 
        mem[mem_portA_addr] <= {r, g, b};
end

// BRAM port B read
reg [$clog2(WIDTH)-1:0] xx  /* xsynthesis syn_keep=1 */; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy /* xsynthesis syn_keep=1 */;
assign mem_portB_addr = yy[4:0] * WIDTH + xx;
always @(posedge clk_pixel) begin
    mem_portB_rdata <= mem[mem_portB_addr];
end

// Full frame (FULL_FRAME = 1): every pixel is also kept in a WIDTH x HEIGHT frame, read at
// the same position as the line buffer. The core is paused while the menu is shown, so this
// holds its last picture.
localparam FF_DEPTH = WIDTH * HEIGHT;
reg [COLOR_WIDTH-1:0] ff_rdata;
generate
if (FULL_FRAME) begin : g_ff
    reg [COLOR_WIDTH-1:0] ff [0:FF_DEPTH-1];
    always @(posedge clk)
        if (ce_pix & ~ce_pix_r)
            ff[y * WIDTH + x] <= {r, g, b};
    always @(posedge clk_pixel)
        ff_rdata <= ff[yy * WIDTH + xx];
end else begin : g_noff
    always @* ff_rdata = 0;
end
endgenerate

// Video synchronization
reg sync_done = 1'b0;
reg hdmi_first_line, hdmi_first_line_r, hdmi_first_line_rr;
always @(posedge clk) begin
    hdmi_first_line_r <= hdmi_first_line;
    hdmi_first_line_rr <= hdmi_first_line_r;
    if (~sync_done) begin
        if (~pause_core) begin
            if (y == 1 && x == 0)                           // halt on core starting line 1
                pause_core <= 1'b1;
        end else if (hdmi_first_line_rr && pause_core && ~(overlay & ~osd_strip)) begin     // resume when HDMI start line 0, held while the menu is shown (not the strip)
            pause_core <= 1'b0;
            sync_done <= 1'b1;
        end
    end
    if (y == 100) sync_done <= 1'b0;                    // reset sync_done for next frame
end
always @(posedge clk_pixel) begin
    if (cy == 0 && cx >= 160)                           // start position of 4:3 frame
        hdmi_first_line <= 1;
    else
        hdmi_first_line <= 0;
end

// audio stuff
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always @(posedge clk_pixel) begin
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider++;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

// Audio into clk_pixel, all 16 bits from one sample (audio_cdc.v). The mix is signed with
// silence at 0, so both sides power up at 0.
wire [15:0] audio_pix_l, audio_pix_r;
audio_cdc #(.W(16), .INIT(16'd0)) audio_cdc_inst (
    .clk_src(clk), .in_l(audio_left), .in_r(audio_right),
    .clk_dst(clk_pixel), .out_l(audio_pix_l), .out_r(audio_pix_r)
);
logic [15:0] audio_sample_word [1:0];
assign audio_sample_word[0] = audio_pix_l;
assign audio_sample_word[1] = audio_pix_r;

//
// Video
//
reg [23:0] rgb;             // actual RGB output
reg active                  /* xsynthesis syn_keep=1 */;
reg [10:0] xcnt             /* xsynthesis syn_keep=1 */;
reg [10:0] ycnt             /* xsynthesis syn_keep=1 */;                  // fractional scaling counters
reg [9:0] cy_r;
localparam XSTART = (1280 - 960) / 2;   // 960:720 = 4:3
localparam XSTOP = (1280 + 960) / 2;

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
// xcnt and ycnt are fractional scaling counters.
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + width;
    ycnt_next = ycnt + height;

    active_t = 0;
    if (cx == XSTART - 1) begin
        active_t = 1;
        active <= 1;
    end else if (cx == XSTOP - 1) begin
        active_t = 0;
        active <= 0;
    end

    if (active_t | active) begin        // increment xx
        xcnt <= xcnt_next;
        if (xcnt_next >= 960) begin
            xcnt <= xcnt_next - 960;
            xx <= xx + 1;
        end
    end

    cy_r <= cy;
    if (cy[0] != cy_r[0]) begin         // increment yy at new lines
        ycnt <= ycnt_next;
        if (ycnt_next >= 720) begin
            ycnt <= ycnt_next - 720;
            yy <= yy + 1;
        end
    end

    if (cx == 0) begin
        xx <= 0;
        xcnt <= 0;
    end
    
    if (cy == 0) begin
        yy <= 0;
        ycnt <= 0;
    end 

end

//
// Menu: textdisp's 256x224 at 3x in a 768x672 window, the same pixels as
// common/video/video_out.v. textdisp returns the color of (overlay_x, overlay_y) 2 cycles
// later and needs at least 3 cycles per x step. The position counter works on pixel
// hpos = cx + LAT; rgb, which the HDMI encoder reads, is stage 6.
//
localparam LAT = 6;
localparam [10:0] LINE_EVT = 11'd1290;  // next line's overlay_y is set here, in horizontal blanking
localparam [10:0] MENU_X0 = 11'd256;    // window left edge
localparam [9:0]  MENU_Y0 = 10'd24;     // window top edge
// Strip (osd_strip, the volume bar): text columns 8-23 of rows 23-24, 128x16 pixels (the
// firmware's OVERLAY_STRIP_*), on a band 2 pixels (6 output pixels) wider on every side
localparam [10:0] STRIP_X0 = MENU_X0 + 11'd192;     // column 8
localparam [10:0] STRIP_X1 = MENU_X0 + 11'd576;     // after column 23
localparam [9:0]  STRIP_Y0 = MENU_Y0 + 10'd552;     // row 23
localparam [9:0]  STRIP_Y1 = MENU_Y0 + 10'd600;     // after row 24

wire [10:0] hpos = cx + LAT;
wire [9:0] next_line = cy == 10'd749 ? 10'd0 : cy + 10'd1;
reg [7:0] mx, my;
reg [1:0] mx_ph, my_ph;
assign overlay_x = mx;
assign overlay_y = my;
always @(posedge clk_pixel) begin
    if (hpos == MENU_X0 - 11'd1) begin
        mx <= 8'd255;
        mx_ph <= 0;
    end else if (mx_ph == 2'd2) begin
        mx <= mx + 8'd1;
        mx_ph <= 0;
    end else
        mx_ph <= mx_ph + 2'd1;

    if (cx == LINE_EVT) begin
        if (next_line == MENU_Y0) begin
            my <= 0;
            my_ph <= 0;
        end else if (my_ph == 2'd2) begin
            my <= my + 8'd1;
            my_ph <= 0;
        end else
            my_ph <= my_ph + 2'd1;
    end
end

wire menu_win0 = hpos >= MENU_X0 && hpos < MENU_X0 + 11'd768 &&
                 cy >= MENU_Y0 && cy < MENU_Y0 + 10'd672;
reg [4:0] menu_win_d;
always @(posedge clk_pixel)
    menu_win_d <= {menu_win_d[3:0], menu_win0};
wire menu_win5 = menu_win_d[4];
wire strip_win0 = hpos >= STRIP_X0 && hpos < STRIP_X1 && cy >= STRIP_Y0 && cy < STRIP_Y1;
wire band_win0 = hpos >= STRIP_X0 - 11'd6 && hpos < STRIP_X1 + 11'd6 &&
                 cy >= STRIP_Y0 - 10'd6 && cy < STRIP_Y1 + 10'd6;
reg [4:0] strip_win_d, band_win_d;
always @(posedge clk_pixel) begin
    strip_win_d <= {strip_win_d[3:0], strip_win0};
    band_win_d <= {band_win_d[3:0], band_win0};
end
wire strip_win5 = strip_win_d[4];
wire band_win5 = band_win_d[4];

// osd_strip from the core clock domain: two flip-flops, the first *_meta
reg strip_meta, strip_r;
always @(posedge clk_pixel)
    {strip_r, strip_meta} <= {strip_meta, osd_strip};

// BGR5 to RGB888, low bits repeated so that 31 becomes 255
wire [23:0] menu_rgb = {overlay_color[4:0],   overlay_color[4:2],
                        overlay_color[9:5],   overlay_color[9:7],
                        overlay_color[14:10], overlay_color[14:12]};

// calc rgb value to hdmi. Under the menu: with FULL_FRAME the paused game dimmed to 1/4
// behind the menu's black pixels; without it the menu on black (the line buffer holds only
// 32 lines). The strip (volume bar): white on a band of the running game dimmed to 1/8
// with a green tint. Black around the picture.
always @(posedge clk_pixel) begin
    if (overlay && ~strip_r)
        rgb <= menu_win5 && (!FULL_FRAME || overlay_color != 15'd0) ? menu_rgb
             : FULL_FRAME && active ?
               {2'b0, ff_rdata[COLOR_BITS*2 +: COLOR_BITS], {(6-COLOR_BITS){1'b0}},
                2'b0, ff_rdata[COLOR_BITS   +: COLOR_BITS], {(6-COLOR_BITS){1'b0}},
                2'b0, ff_rdata[0            +: COLOR_BITS], {(6-COLOR_BITS){1'b0}}}     // RGB4 to RGB8 / 4
             : 24'h000000;
    else if (overlay && band_win5)
        rgb <= strip_win5 && overlay_color != 15'd0 ? 24'hFFFFFF
             : active ?
               {3'b000, mem_portB_rdata[COLOR_BITS*2 +: COLOR_BITS], {(5-COLOR_BITS){1'b0}},
                3'b010, mem_portB_rdata[COLOR_BITS   +: COLOR_BITS], {(5-COLOR_BITS){1'b0}},
                3'b000, mem_portB_rdata[0            +: COLOR_BITS], {(5-COLOR_BITS){1'b0}}}    // RGB4 to RGB8 / 8, green + 64
             : 24'h004000;
    else if (active)
        rgb <= {mem_portB_rdata[COLOR_BITS*2 +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
                mem_portB_rdata[COLOR_BITS   +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
                mem_portB_rdata[0            +: COLOR_BITS], {(8-COLOR_BITS){1'b0}}};    // RGB4 to RGB8
    else
        rgb <= 24'h000000;
end

// HDMI output.
logic[2:0] tmds;

localparam FRAMEWIDTH = 1280;
localparam FRAMEHEIGHT = 720;
localparam TOTALWIDTH = 1650;
localparam TOTALHEIGHT = 750;
localparam SCALE = 5;
localparam VIDEOID = 4;
localparam VIDEO_REFRESH = 60.0;
localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;
hdmi #( .VIDEO_ID_CODE(VIDEOID), 
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .RGB_QUANTIZATION_RANGE(2'b01),    // limited range (16-235), converted in hdmi.sv
        .CONTENT_TYPE(2'b11),              // Game
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0) )

hdmi( .clk_pixel_x5(clk_5x_pixel), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .rgb(rgb), 
        .reset( /* ~resetn */ ),
        .audio_sample_word(audio_sample_word),
        .volume(volume),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width(),
        .frame_height() );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

endmodule
