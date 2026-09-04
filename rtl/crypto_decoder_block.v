// crypto_decoder_block.v
//
// Reverse of crypto_encoder_block.v: plaintext = (ciphertext - key)
// mod 4096 (2^12), via the output width's implicit truncation --
// exact inverse of the encoder's addition.
module crypto_decoder_block (
    input  [11:0] ciphertext_in,
    input  [7:0]  shift_key_in, // Must be the same key used for encryption
    output [11:0] plaintext_out
);

    // Decryption: P = (C - K) mod 4096 (2^12)
    assign plaintext_out = ciphertext_in - shift_key_in;

endmodule
