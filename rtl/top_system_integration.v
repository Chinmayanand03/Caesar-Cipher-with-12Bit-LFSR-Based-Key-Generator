// top_system_integration.v
//
// Connects UART RX/TX, the system control FSM, and the encoder/decoder
// into one pipeline: two received bytes are assembled into one 12-bit
// block, encrypted, decrypted (round-trip self-check), and the
// decrypted 12-bit block is split back into two bytes for
// transmission.
//
// Real fix vs. the original report: baud_tick was previously
// `assign baud_tick = 1'b1;` -- permanently high, so every FSM state
// advanced one bit per clock (50 Mbps at 50 MHz, not any real UART
// baud rate), directly contradicting the report's claim that "baud
// rate accuracy" was verified. Replaced with a real baud_tick_gen
// instance dividing the clock down to BAUD_RATE.
module top_system_integration #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BAUD_RATE   = 115_200
) (
    // System I/O
    input  clk,
    input  reset,
    input  serial_rx,
    output serial_tx,
    // Debug/Verification Output
    output [3:0] fsm_state_out,
    output [11:0] debug_rx_block,
    output [11:0] debug_ciphertext,
    output [11:0] debug_decoded_data,
    output [7:0] current_shift_key
);

    // --- INTERNAL WIRES ---
    // Timing
    wire baud_tick;

    // UART RX Interface Wires
    wire rx_data_ready;
    wire [7:0] rx_data_out;
    wire rx_data_ack;

    // UART TX Interface Wires
    wire tx_start_command;
    wire tx_busy;

    // FSM Control Wires
    wire lfsr_shift_en;
    wire lfsr_load_seed;

    // Data Buffers
    reg [11:0] block_buffer; // Stores the two 8-bit bytes as one 12-bit block
    reg [3:0]  byte_index;   // 0 for Byte 0 (LSBs), 1 for Byte 1 (MSBs)

    // Cipher Data Wires
    wire [11:0] ciphertext_wire;
    wire [11:0] decrypted_data_wire;
    wire [7:0]  shift_key_wire;

    // TX Data MUX
    reg [7:0] tx_data_select; // Output byte sent to UART TX

    // --- FSM State Values (From system_control_fsm.v) ---
    localparam [3:0] S_TX_START = 4'h7;
    localparam [3:0] S_TX_WAIT  = 4'h8;

    // --- 1. BAUD-RATE GENERATOR (real, replaces the original's
    //     hardwired baud_tick = 1'b1) ---
    baud_tick_gen #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) baud_gen_inst (
        .clk(clk),
        .reset(reset),
        .baud_tick(baud_tick)
    );

    // --- 2. SYSTEM CONTROL FSM (The Boss) ---
    system_control_fsm fsm_inst (
        .clk(clk),
        .reset(reset),
        // Status Inputs
        .rx_data_ready(rx_data_ready),
        .tx_busy(tx_busy),
        // Control Outputs
        .rx_data_ack(rx_data_ack),
        .lfsr_shift_en(lfsr_shift_en),
        .lfsr_load_seed(lfsr_load_seed),
        .start_encode(),
        .start_decode(),
        .tx_start_command(tx_start_command),
        .fsm_state_out(fsm_state_out)
    );

    // --- 3. UART RECEIVER FSM (The Listener) ---
    uart_receiver_fsm rx_inst (
        .clk(clk),
        .reset(reset),
        .baud_tick_in(baud_tick),
        .serial_rx(serial_rx),
        .rx_data_ready(rx_data_ready),
        .rx_data_ack(rx_data_ack),
        .rx_data_out(rx_data_out)
    );

    // --- 4. UART TRANSMITTER FSM (The Speaker) ---
    uart_transmitter_fsm tx_inst (
        .clk(clk),
        .reset(reset),
        .baud_tick_in(baud_tick),
        .serial_tx(serial_tx),
        .tx_data_in(tx_data_select), // Connect MUX output
        .tx_start_command(tx_start_command),
        .tx_busy(tx_busy)
    );

    // --- 5. CRYPTO ENCODER BLOCK (LFSR + ENCRYPT) ---
    crypto_encoder_block encoder_inst (
        .clk(clk),
        .reset(reset),
        .lfsr_shift_en(lfsr_shift_en),
        .lfsr_load_seed(lfsr_load_seed),
        .plaintext_in(block_buffer), // Input is the assembled 12-bit block
        .ciphertext_out(ciphertext_wire),
        .current_shift_key(shift_key_wire)
    );

    // --- 6. CRYPTO DECODER BLOCK (DECRYPT) ---
    crypto_decoder_block decoder_inst (
        .ciphertext_in(ciphertext_wire),
        .shift_key_in(shift_key_wire),
        .plaintext_out(decrypted_data_wire)
    );

    // --- 7. DATA BUFFERS AND BYTE ASSEMBLY (Sequential) ---
    // This logic handles assembling two 8-bit UART bytes into one 12-bit block
    always @(posedge clk) begin
        if (reset) begin
            block_buffer <= 12'h000;
            byte_index   <= 4'h0;
        end else begin
            if (rx_data_ready && rx_data_ack) begin
                if (byte_index == 4'h0) begin
                    // Store Byte 0 (LSB 8 bits) and wait for next byte
                    block_buffer[7:0] <= rx_data_out;
                    byte_index <= 4'h1;
                end else if (byte_index == 4'h1) begin
                    // Store Byte 1 (MSB 4 bits) and reset index
                    block_buffer[11:8] <= rx_data_out[3:0]; // Only take 4 bits from the 8-bit byte
                    byte_index <= 4'h0;
                end
            end
        end
    end

    // --- 8. TRANSMITTER MUX (Combinational) ---
    // Selects which part of the decoded data block to send back over the UART
    always @(*) begin
        case (fsm_state_out)
            S_TX_START: tx_data_select = decrypted_data_wire[7:0];
            S_TX_WAIT:  tx_data_select = {4'b0000, decrypted_data_wire[11:8]};
            default:    tx_data_select = 8'h00;
        endcase
    end

    // --- 9. DEBUG CONNECTIONS ---
    assign debug_rx_block     = block_buffer;
    assign debug_ciphertext   = ciphertext_wire;
    assign debug_decoded_data = decrypted_data_wire;
    assign current_shift_key  = shift_key_wire;

endmodule
