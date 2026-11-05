// 32x28 text display in 8x8 font, with a picorv32 register I/O interface
// to print characters to the display.

module textdisp(
	input             clk,              // main logic clock
    input             hclk,             // hdmi clock
	input             resetn,

    input      [7:0]  x,                // 0 - 255
    input      [7:0]  y,                // 0 - 223
    output reg [14:0] color,            // pixel color, NOTE: 2-cycle latency
                                        // we need 1 cycle to fetch character and 1 cycle to fetch font byte

    // PicoRV32 I/O interface, one command per write:
    // [31:24] = 0: print a character. [23:16]: x, [15:8]: y, [7:0]: character (Latin-1)
    // [31:24] = 1: highlight bar register. [17:16]: register, [7:0]: value. Registers:
    //              0: row (0xFF: none), 1: first column, 2: last column
	input      [3:0]  reg_char_we,
	input      [31:0] reg_char_di
);

// BGR
localparam [14:0] COLOR_BACK    = 15'b00000_00000_00000;    // see-through: the video path shows what's behind
localparam [14:0] COLOR_TEXT    = 15'b11010_11100_11100;    // off-white
localparam [14:0] COLOR_HL      = 15'b10110_01011_00101;    // accent blue, behind highlighted characters
localparam [14:0] COLOR_HINT    = 15'b01110_01110_01110;    // gray, for the button hints / status row
localparam [14:0] COLOR_DIM     = 15'b01000_01000_01000;    // dark gray, for the footer (version)
// parameter [14:0] COLOR_LOGO    = 15'b00000_10101_00000;    // green
parameter [14:0] COLOR_LOGO    = 15'b00000_10011_11111;

// 72x14 pixels 1bpp logo, the header (rows 0-4; content starts at row 5)
localparam LOGO_X = 128-36;
localparam LOGO_Y = 22;
localparam [4:0] HINT_ROW = 25;
localparam [4:0] FOOTER_ROW = 27;

//
// Pixel output logic for characters and logo:
// 1. To improve timing, output logic is broken into 3 cycles.
// 2. Everything written on clk and read on hclk goes through the dual-port text BRAM, so no
//    register crosses between the clocks.
//
// Text BRAM, written on clk (port A), read on hclk (port B):
// $000-$37F: character buffer (32*28)
// $380-$3FD: logo (14 rows of 9 bytes)
// $400-$402: highlight bar: row (0xFF: none), first column, last column
// Font ROM: 256 characters (Latin-1), 8 bytes each, read on hclk.
// Both are initialized in gowin_dpb_menu.v (written by scripts/font_glyphs.py).
//
reg [10:0] text_addr;
wire [7:0] text_do;
wire [7:0] font_do;
reg is_footer;
reg is_hint;
reg is_hl;                  // character cell is inside the highlight bar

wire [7:0] cmd = reg_char_di[31:24];
wire [4:0] text_x = reg_char_di[20:16];
wire [4:0] text_y = reg_char_di[12:8];

gowin_dpb_menu menu_mem (
    .clka(clk), .wrea(reg_char_we[0] && (cmd == 8'd0 || cmd == 8'd1)),
    .ada(cmd == 8'd0 ? {1'b0, text_y, text_x} : {9'b100_0000_00, reg_char_di[17:16]}),
    .dina(reg_char_di[7:0]),

    .clkb(hclk), .adb(text_addr), .doutb(text_do),
    .adf({text_do, y[2:0]}), .doutf(font_do)   // the character just read from the text BRAM
);

// Highlight bar registers, read from the text BRAM one per character fetch (in FETCH_FONT,
// when its port is free), so a change shows within a few pixels
reg [7:0] hl_row = 8'hFF, hl_x0, hl_x1;
reg [1:0] hl_idx = 0;

reg [6:0] logo_addr;
reg [2:0] logo_xoff;
reg logo_active;
reg [14:0] color_buf;
reg [7:0] x_r;

// Rendering state machine
reg [2:0] state;
localparam MAIN = 0;        // default state and fetching character
localparam FETCH_FONT = 1;  // fetch font byte (and a highlight register)
localparam FETCH_LOGO = 2;  // fetch logo byte
localparam OUTPUT = 3;      // output new pixel and fetch character

always @* begin             // address and output logic
    color = color_buf;
    case (state)
    MAIN:           text_addr = {1'b0, y[7:3], x[7:3]};
    FETCH_FONT:     text_addr = {9'b100_0000_00, hl_idx};
    FETCH_LOGO:     text_addr = {4'b0111, logo_addr};
    OUTPUT: begin
        text_addr = {1'b0, y[7:3], x[7:3]};
        if (logo_active)
            color = text_do[logo_xoff] ? COLOR_LOGO : COLOR_BACK;
        else
            color = font_do[x[2:0]] ? (is_footer ? COLOR_DIM : is_hint ? COLOR_HINT : COLOR_TEXT)
                                    : (is_hl ? COLOR_HL : COLOR_BACK);
    end
    default: text_addr = 0;
    endcase
end

always @(posedge hclk) begin    // actual state machine
    reg [7:0] logo_x, logo_y;

    x_r <= x;
    
    case (state)
    MAIN, OUTPUT: begin
        state <= MAIN;
        if (state == OUTPUT) color_buf <= color;
        if (state == OUTPUT && !logo_active) begin  // the highlight register read in FETCH_FONT
            case (hl_idx)
            2'd0: hl_row <= text_do;
            2'd1: hl_x0 <= text_do;
            default: hl_x1 <= text_do;
            endcase
            hl_idx <= hl_idx == 2'd2 ? 2'd0 : hl_idx + 2'd1;
        end
        if (x[0] != x_r[0]) begin   // moved to new pixel
            if (x >= LOGO_X && x < LOGO_X+72 && y >= LOGO_Y && y < LOGO_Y+14) begin
                state <= FETCH_LOGO;
                logo_active <= 1;
            end else begin
                state <= FETCH_FONT;
                logo_active <= 0;
            end
        end
        logo_x = x - LOGO_X;
        logo_y = y - LOGO_Y;
        logo_addr <= {logo_y, 3'b0} + logo_y + logo_x[6:3];
        logo_xoff <= logo_x[2:0];
        is_footer <= y[7:3] == FOOTER_ROW;
        is_hint <= y[7:3] == HINT_ROW;
        is_hl <= {3'b0, y[7:3]} == hl_row && {3'b0, x[7:3]} >= hl_x0 && {3'b0, x[7:3]} <= hl_x1;
    end

    FETCH_FONT: state <= OUTPUT;

    FETCH_LOGO: state <= OUTPUT;

    default: ;
    endcase
end

endmodule