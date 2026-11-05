// Audio sample into another clock domain, with every bit of each output from one sample.
//
// A two-flop synchronizer per bit can tear a multi-bit sample: if the sample changes near a
// clk_dst edge, some bits take the new value and some the old, and near zero (0xFFFF <->
// 0x0000) the torn value is a full-scale spike. Instead:
//
// - Source side: every 2^HOLD_BITS clk_src cycles, copy the sample into a holding register
//   and flip a toggle.
// - Destination side: pass the toggle through three flip-flops; when it has flipped, copy
//   the holding register. By then it has been stable for at least two clk_dst cycles, and it
//   stays stable until the next update, 2^HOLD_BITS clk_src cycles after the last one.
//
// Requirement: 4 clk_dst periods < 2^HOLD_BITS clk_src periods (at HOLD_BITS = 6 and a
// 74.25 MHz clk_dst, any clk_src above 4.7 MHz). The sample reaches clk_dst every
// 2^HOLD_BITS clk_src cycles: 64 cycles of a 21 MHz clock are 3 us, far shorter than one
// 48 kHz audio sample (21 us).
//
// Timing: the first destination stage of the toggle (toggle_meta) and the copy of the
// holding register (held_meta) are named *_meta, so each core's
// `set_false_path -to [get_regs {*_meta*}]` covers both paths that cross clocks.
module audio_cdc #(
    parameter W         = 16,
    parameter HOLD_BITS = 6,
    parameter [W-1:0] INIT = {W{1'b0}}  // power-up value on both sides (the core's silence)
) (
    input              clk_src,
    input      [W-1:0] in_l,            // clk_src domain
    input      [W-1:0] in_r,
    input              clk_dst,
    output     [W-1:0] out_l,           // clk_dst domain
    output     [W-1:0] out_r
);

// Source side: hold the sample and flip the toggle
reg [HOLD_BITS-1:0] hold_count = {HOLD_BITS{1'b0}};
reg [W-1:0]         held_l = INIT, held_r = INIT;
reg                 held_toggle = 1'b0;
always @(posedge clk_src) begin
    hold_count <= hold_count + 1'b1;
    if (hold_count == {HOLD_BITS{1'b0}}) begin
        held_l <= in_l;
        held_r <= in_r;
        held_toggle <= ~held_toggle;
    end
end

// Destination side: synchronize the toggle; copy the held sample when it flips
reg         toggle_meta = 1'b0;
reg [1:0]   toggle_sync = 2'b00;
reg [W-1:0] held_meta_l = INIT, held_meta_r = INIT;
always @(posedge clk_dst) begin
    toggle_meta <= held_toggle;
    toggle_sync <= {toggle_sync[0], toggle_meta};
    if (toggle_sync[1] ^ toggle_sync[0]) begin
        held_meta_l <= held_l;
        held_meta_r <= held_r;
    end
end
assign out_l = held_meta_l;
assign out_r = held_meta_r;

endmodule
