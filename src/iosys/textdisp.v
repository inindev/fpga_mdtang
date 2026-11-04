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

    // PicoRV32 I/O interface. Every write updates one character
    // [23:16]: x, [15:8]: y, [7-0]: character to print
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
// 2. Char buffer, font rom, logo rom are all stored in the same bram 
//    block to save LUTs.
//
reg [10:0] mem_addr_b;
reg [7:0] mem_do_b;
reg is_footer;
reg is_hint;
reg is_hl;                  // character has bit 7 set: drawn on the highlight color
reg [14:0] overlay_color_buf;

wire [1:0] cmd = reg_char_di[31:24];
wire [4:0] text_x = reg_char_di[20:16];
wire [4:0] text_y = reg_char_di[12:8];
wire [7:0] text_char = reg_char_di[7:0];    // [7]: highlight, [6:0]: character

// Char buffer, font and logo rom backed by Dual-port BRAM (total 2KB)
// this is initialized with font.mi (font.vh + logo.vh)
// $000-$37F: Character buffer RAM (32*28)
// $380-$3FF: Logo ROM (14*9 bytes)
// $400-$800: Font ROM
gowin_dpb_menu menu_mem (
    .clka(clk), .reseta(1'b0), .ocea(), .cea(1'b1), 
    .ada({1'b0, text_y, text_x}), .wrea(reg_char_we[0] && cmd == 2'd0),
    .dina(text_char), .douta(),

    .clkb(hclk), .resetb(1'b0), .oceb(), .ceb(1'b1), 
    .adb(mem_addr_b), .wreb(1'b0), 
    .dinb(), .doutb(mem_do_b)
);

reg [6:0] logo_addr;
reg [2:0] logo_xoff;
reg logo_active;
reg [14:0] color_buf;
reg [7:0] x_r;

// Rendering state machine
reg [2:0] state;
localparam MAIN = 0;        // default state and fetching character
localparam FETCH_FONT = 1;  // fetch font byte
localparam FETCH_LOGO = 2;  // fetch logo byte
localparam OUTPUT = 3;      // output new pixel and fetch character

always @* begin             // address and output logic
    color = color_buf;
    case (state)
    MAIN:           mem_addr_b = {1'b0, y[7:3], x[7:3]};   
    FETCH_FONT:     mem_addr_b = {1'b1, mem_do_b[6:0], y[2:0]};
    FETCH_LOGO:     mem_addr_b = {4'b0111, logo_addr};
    OUTPUT: begin
        mem_addr_b = {1'b0, y[7:3], x[7:3]};
        if (logo_active)
            color = mem_do_b[logo_xoff] ? COLOR_LOGO : COLOR_BACK;
        else
            color = mem_do_b[x[2:0]] ? (is_footer ? COLOR_DIM : is_hint ? COLOR_HINT : COLOR_TEXT)
                                     : (is_hl ? COLOR_HL : COLOR_BACK);
    end
    default: mem_addr_b = 0;
    endcase
end

always @(posedge hclk) begin    // actual state machine
    reg [7:0] logo_x, logo_y;

    x_r <= x;
    
    case (state)
    MAIN, OUTPUT: begin
        state <= MAIN;
        if (state == OUTPUT) color_buf <= color;
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
    end

    FETCH_FONT: begin
        is_hl <= mem_do_b[7];       // the character, read for the font address
        state <= OUTPUT;
    end

    FETCH_LOGO: state <= OUTPUT;

    default: ;
    endcase
end

endmodule