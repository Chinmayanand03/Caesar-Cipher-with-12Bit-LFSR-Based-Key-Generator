// crypto_encoder_block.v
//
// 12-bit LFSR (maximal-length taps at bits 11,5,3,0 -- verified by
// simulation in tb/lfsr_period_test.v to have period 2^12 - 1 = 4095,
// i.e. every nonzero 12-bit state visited exactly once per cycle)
// driving an 8-bit dynamic Caesar-cipher shift key. The key itself is
// only 8 bits (the low byte of the 12-bit LFSR state), not 12 -- so
// while the full 12-bit *state* doesn't repeat for 4095 shifts, the
// 8-bit *key* has only 256 possible values and repeats much sooner by
// simple pigeonhole (measured: the first repeated key value appears by
// shift 31 of the real seed sequence, not after thousands of shifts --
// see docs/verification-log.md). Don't confuse the two: this design's
// dynamic-key claim is "the key changes every block, sourced from a
// verified maximal-length LFSR," not "the key doesn't repeat for 4095
// blocks."
//
// ciphertext_out = plaintext_in + shift_key_reg, truncated to 12 bits
// by the output width -- i.e. addition mod 4096, matching
// crypto_decoder_block.v's subtraction mod 4096 exactly.
module crypto_encoder_block(
    input  clk,
    input  reset,
    input  lfsr_shift_en,
    input  lfsr_load_seed,
    input  [11:0] plaintext_in,
    output reg [11:0] ciphertext_out,
    output [7:0] current_shift_key
);

    reg [11:0] lfsr_state;
    reg [7:0]  shift_key_reg;

    // Feedback using primitive polynomial taps
    wire lfsr_feedback_bit;
    assign lfsr_feedback_bit = lfsr_state[11] ^ lfsr_state[5] ^ lfsr_state[3] ^ lfsr_state[0];

    // LFSR state logic
    always @(posedge clk) begin
        if (reset)
            lfsr_state <= 12'h001;
        else if (lfsr_load_seed)
            lfsr_state <= 12'h0A8; // Ensure 12-bit seed
        else if (lfsr_shift_en)
            lfsr_state <= {lfsr_state[10:0], lfsr_feedback_bit};
    end

    // Key derivation
    always @(*) begin
        shift_key_reg = lfsr_state[7:0];
        if (shift_key_reg == 8'h00)
            shift_key_reg = 8'h01;
    end

    assign current_shift_key = shift_key_reg;

    // Caesar encryption
    always @(*) begin
        ciphertext_out = plaintext_in + shift_key_reg;
    end

endmodule
