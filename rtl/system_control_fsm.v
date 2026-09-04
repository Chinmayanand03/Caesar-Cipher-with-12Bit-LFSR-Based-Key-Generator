// system_control_fsm.v
//
// Coordinates the whole pipeline: load the LFSR seed, receive two
// UART bytes, shift the key and encrypt/decrypt (both combinational,
// one FSM state each just to pace the sequence), then transmit the
// two resulting bytes back out.
//
// Note relative to the original report appendix: the S_RX_BYTE0 and
// S_ENCRYPT case items in the output-logic block were each missing
// their closing `end` before the next case label in the PDF
// transcription (which would not compile as-is -- a case label can't
// appear inside another case item's begin/end block). Reconstructed
// here with correct begin/end nesting; the intended behavior per the
// report's own prose description ("Functional Modules Explanation")
// is unchanged.
//
// Real bug found and fixed by actually simulating this (not present
// in, or fixable from, the report/appendix alone): rx_data_ready is a
// LEVEL held high for two clock cycles by uart_receiver_fsm (one cycle
// for rx_data_ack to register, one more for the RX FSM's own
// registered clear to take effect) -- but S_RX_WAIT and S_RX_BYTE0
// each sampled the raw level combinationally, one cycle apart. The
// result: the *same* single byte-arrival pulse satisfied both states'
// "a byte arrived" condition, so the FSM advanced past S_RX_BYTE0 (and
// re-asserted rx_data_ack) without ever waiting for byte 1 to
// actually arrive on the wire. Verified via simulation trace (see
// docs/verification-log.md): block 0 still decoded correctly by pure
// coincidence of how the byte-assembly index's parity happened to
// realign one byte late; block 1 then genuinely deadlocked once that
// one-byte skew compounded. Fixed with real rising-edge detection on
// rx_data_ready (rx_data_ready_pulse below) instead of sampling the
// raw level, so each state consumes exactly one genuinely new byte
// arrival.
module system_control_fsm (
    // Clock and Reset
    input  clk,
    input  reset,
    // Status Inputs
    input  rx_data_ready,   // From UART Receiver
    input  tx_busy,         // From UART Transmitter
    // Control Outputs
    output reg rx_data_ack,       // Acknowledge received data
    output reg lfsr_shift_en,     // Enable key generation/encryption
    output reg lfsr_load_seed,    // Reset key sequence
    output reg start_encode,      // Command to trigger encryption (combinational)
    output reg start_decode,      // Command to trigger decryption (combinational)
    output reg tx_start_command,  // Command to start transmission
    // Debug Output
    output [3:0] fsm_state_out
);

    // --- FSM States (Local definitions shared externally via port) ---
    localparam [3:0]
        S_IDLE          = 4'h0,
        S_LOAD_SEED     = 4'h1,
        S_RX_WAIT       = 4'h2,
        S_RX_BYTE0      = 4'h3,
        S_SHIFT_KEY     = 4'h4,
        S_ENCRYPT       = 4'h5,
        S_DECRYPT       = 4'h6,
        S_TX_START      = 4'h7,
        S_TX_WAIT       = 4'h8,
        S_TX_WAIT_FINAL = 4'h9;

    reg [3:0] state, next_state;

    // Real bug found by simulation (see docs/verification-log.md):
    // S_IDLE unconditionally asserted lfsr_load_seed every time the
    // FSM passed through it -- which happens once per BLOCK, not just
    // once at startup (the FSM cycles ...->S_TX_WAIT_FINAL->S_IDLE->
    // S_LOAD_SEED->S_RX_WAIT for every block). That reseeds the LFSR
    // to the same fixed 12'h0A8 before every single block, so it only
    // ever advances by exactly one shift from the same starting point
    // -- every block used the identical key (0x50), making this a
    // static-key cipher in practice despite the "dynamic key" design
    // intent stated in the report (and step 1 of its own described
    // algorithm flow, "Initialization: System resets and loads the
    // LFSR with a seed value," which describes a one-time step, not a
    // per-block one). `seeded` latches after the real, once-only
    // post-reset seed load, gating S_IDLE's lfsr_load_seed to that
    // first pass only -- every later visit to S_IDLE (end of each
    // block) leaves the LFSR's running state alone, so lfsr_shift_en
    // in S_SHIFT_KEY genuinely advances it block over block.
    reg seeded;
    always @(posedge clk) begin
        if (reset)
            seeded <= 1'b0;
        else if (state == S_LOAD_SEED)
            seeded <= 1'b1;
    end

    // --- 1. State Register (Sequential) ---
    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
        end else begin
            state <= next_state;
        end
    end

    assign fsm_state_out = state;

    // --- 1b. Rising-edge detector for rx_data_ready ---
    // See the header comment: rx_data_ready is held high for 2 cycles
    // by the receiver, but this FSM must only react to it once per
    // real byte arrival. rx_data_ready_pulse is high for exactly one
    // cycle per rising edge, regardless of how long the level stays
    // asserted afterward.
    reg rx_data_ready_d;
    always @(posedge clk) begin
        if (reset)
            rx_data_ready_d <= 1'b0;
        else
            rx_data_ready_d <= rx_data_ready;
    end
    wire rx_data_ready_pulse = rx_data_ready & ~rx_data_ready_d;

    // --- 2. Next State Logic (Combinational) ---
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                next_state = S_LOAD_SEED; // Proceed to load seed on reset completion
            end
            S_LOAD_SEED: begin
                next_state = S_RX_WAIT; // Seed loaded (1 cycle), wait for UART
            end
            S_RX_WAIT: begin
                if (rx_data_ready_pulse) // First byte (Byte 0) received
                    next_state = S_RX_BYTE0;
            end
            S_RX_BYTE0: begin
                if (rx_data_ready_pulse) // Second byte (Byte 1) received
                    next_state = S_SHIFT_KEY;
            end
            S_SHIFT_KEY: begin
                next_state = S_ENCRYPT; // LFSR shifted (1 cycle), encrypt
            end
            S_ENCRYPT: begin
                next_state = S_DECRYPT; // Encryption done (combinational), decrypt
            end
            S_DECRYPT: begin
                next_state = S_TX_START; // Decryption done, prepare TX
            end
            S_TX_START: begin
                if (~tx_busy) // TX command issued, wait for TX to start (next cycle)
                    next_state = S_TX_WAIT;
            end
            S_TX_WAIT: begin
                if (~tx_busy) // TX finished for the first byte
                    next_state = S_TX_WAIT_FINAL;
            end
            S_TX_WAIT_FINAL: begin
                if (~tx_busy) // TX finished for the second byte
                    next_state = S_IDLE; // Cycle complete, wait for new data (or reset)
            end
            default: next_state = S_IDLE;
        endcase
    end

    // --- 3. Output Logic (Sequential Control) ---
    always @(posedge clk) begin
        if (reset) begin
            rx_data_ack      <= 1'b0;
            lfsr_shift_en    <= 1'b0;
            lfsr_load_seed   <= 1'b0;
            start_encode     <= 1'b0;
            start_decode     <= 1'b0;
            tx_start_command <= 1'b0;
        end else begin
            // Default assignments (De-assert all control signals)
            rx_data_ack      <= 1'b0;
            lfsr_shift_en    <= 1'b0;
            lfsr_load_seed   <= 1'b0;
            start_encode     <= 1'b0;
            start_decode     <= 1'b0;
            tx_start_command <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (!seeded) begin
                        lfsr_load_seed <= 1'b1; // Seed the LFSR once, on the real post-reset pass only
                    end
                end

                S_LOAD_SEED: begin
                    // Done loading seed, wait for data
                end

                S_RX_WAIT: begin
                    if (rx_data_ready_pulse) begin
                        rx_data_ack <= 1'b1; // Acknowledge first received byte
                    end
                end

                S_RX_BYTE0: begin
                    if (rx_data_ready_pulse) begin
                        rx_data_ack <= 1'b1; // Acknowledge second received byte
                    end
                end

                S_SHIFT_KEY: begin
                    lfsr_shift_en <= 1'b1; // Shift LFSR, generates new key
                    start_encode  <= 1'b1; // Encryption is combinational, start immediately
                end

                S_ENCRYPT: begin
                    start_decode <= 1'b1; // Decryption is combinational, start immediately
                end

                S_DECRYPT: begin
                    // Data is decoded, prepare to transmit
                end

                S_TX_START: begin
                    tx_start_command <= 1'b1; // Start transmission of byte 0
                end

                S_TX_WAIT: begin
                    if (~tx_busy) // Byte 0 finished transmission
                        tx_start_command <= 1'b1; // Start transmission of byte 1
                end

                S_TX_WAIT_FINAL: begin
                    // Byte 1 finished transmission; next_state logic returns to S_IDLE
                end
            endcase
        end
    end

endmodule
