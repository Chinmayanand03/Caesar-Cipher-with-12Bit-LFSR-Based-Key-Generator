// top_system_testbench.v
//
// Drives 16 blocks (32 bytes: "GEMINI DYNAMIC LFSR CIPHER TEST ") through
// the real UART RX -> encrypt -> decrypt -> UART TX pipeline and checks
// the decrypted output against the known input for each block. (Widened
// from an original 4-block/8-byte test to give a more convincing spread
// of real captured keys -- the dynamic-key *property* itself is proven
// exhaustively by the standalone tb/lfsr_period_test.v, which checks all
// 4095 LFSR shifts; this test's job is UART/round-trip correctness over
// a realistic amount of traffic, not key-space coverage.)
//
// BAUD_DELAY is derived from the same CLK_FREQ_HZ/BAUD_RATE the DUT's
// baud_tick_gen instance uses (50 MHz / 115200 baud -> a 434-cycle,
// 8680 ns bit period) rather than an unexplained magic-number macro --
// the original report's appendix referenced `BAUD_DELAY without
// showing its definition, which only makes sense once there's a real
// baud generator on the DUT side to match it against.
`timescale 1ns/1ps
`define BAUD_DELAY 8680 // (50_000_000 / 115_200 = 434) * 20ns clock period

module top_system_testbench;

    // --- 1. Testbench Parameters ---
    localparam CLK_PERIOD = 20; // 50 MHz clock (20 ns period)
    localparam NUM_BLOCKS = 16; // 32 bytes / 2 bytes per block

    // --- 2. Signals (Wires/Regs for UUT Ports) ---
    reg clk;
    reg reset;
    reg serial_rx;
    wire serial_tx;

    // Debug Outputs from UUT
    wire [3:0] fsm_state_out;
    wire [11:0] debug_rx_block;
    wire [11:0] debug_ciphertext;
    wire [11:0] debug_decoded_data;
    wire [7:0] current_shift_key;

    // --- LOCAL TEST VARIABLES ---
    reg [7:0] test_string [0:2*NUM_BLOCKS-1];
    integer block_index;
    reg [11:0] expected_input_block;
    integer pass_count;
    integer fail_count;
    reg [7:0]  captured_key [0:NUM_BLOCKS-1];        // key actually used per block
    reg [11:0] captured_ciphertext [0:NUM_BLOCKS-1]; // ciphertext actually produced per block
    integer key_check_i, key_check_j;
    integer distinct_keys_ok;
    integer report_i;

    // FSM State Values (from system_control_fsm.v)
    localparam [3:0]
        S_IDLE_VAL     = 4'h0,
        S_RX_WAIT_VAL  = 4'h2,
        S_RX_BYTE0_VAL = 4'h3;

    // --- 3. Instantiation of Unit Under Test (UUT) ---
    top_system_integration #(
        .CLK_FREQ_HZ(50_000_000),
        .BAUD_RATE(115_200)
    ) UUT (
        .clk(clk),
        .reset(reset),
        .serial_rx(serial_rx),
        .serial_tx(serial_tx),
        .fsm_state_out(fsm_state_out),
        .debug_rx_block(debug_rx_block),
        .debug_ciphertext(debug_ciphertext),
        .debug_decoded_data(debug_decoded_data),
        .current_shift_key(current_shift_key)
    );

    // --- 4. Clock Generation ---
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --- 4b. Watchdog: never let a stuck wait() spin forever ---
    initial begin
        #8_000_000; // 8ms sim time -- generously more than the ~4.2ms 16 blocks needs (scaled from the real ~1.04ms measured for the original 4-block test)
        $display("WATCHDOG TIMEOUT: simulation did not finish in time. fsm_state_out=%0d", fsm_state_out);
        $display("TESTBENCH RESULT: FAIL (timeout)");
        $finish;
    end

    // --- 4c. Diagnostic state trace (DEBUG_TRACE) ---
    initial begin
        if ($test$plusargs("DEBUG_TRACE")) begin
            $monitor("t=%0t state=%0d serial_rx=%b serial_tx=%b rx_data_ready=%b rx_data_ack=%b tx_busy=%b tx_start=%b",
                     $time, fsm_state_out, serial_rx, serial_tx, UUT.rx_data_ready, UUT.rx_data_ack, UUT.tx_busy, UUT.tx_start_command);
        end
    end

    // --- 5. Waveform dump for GTKWave ---
    initial begin
        $dumpfile("sim/top_system_testbench.vcd");
        $dumpvars(0, top_system_testbench);
    end

    // --- 6. Reset Sequence and Test Execution ---
    initial begin
        // Initialize signals
        reset = 1'b1;
        serial_rx = 1'b1;
        pass_count = 0;
        fail_count = 0;

        #1000;
        reset = 1'b0;

        // Test Data (32 bytes, processed as 16 blocks): "GEMINI DYNAMIC LFSR CIPHER TEST "
        test_string[0]  = 8'h47; // G
        test_string[1]  = 8'h45; // E
        test_string[2]  = 8'h4D; // M
        test_string[3]  = 8'h49; // I
        test_string[4]  = 8'h4E; // N
        test_string[5]  = 8'h49; // I
        test_string[6]  = 8'h20; // space
        test_string[7]  = 8'h44; // D
        test_string[8]  = 8'h59; // Y
        test_string[9]  = 8'h4E; // N
        test_string[10] = 8'h41; // A
        test_string[11] = 8'h4D; // M
        test_string[12] = 8'h49; // I
        test_string[13] = 8'h43; // C
        test_string[14] = 8'h20; // space
        test_string[15] = 8'h4C; // L
        test_string[16] = 8'h46; // F
        test_string[17] = 8'h53; // S
        test_string[18] = 8'h52; // R
        test_string[19] = 8'h20; // space
        test_string[20] = 8'h43; // C
        test_string[21] = 8'h49; // I
        test_string[22] = 8'h50; // P
        test_string[23] = 8'h48; // H
        test_string[24] = 8'h45; // E
        test_string[25] = 8'h52; // R
        test_string[26] = 8'h20; // space
        test_string[27] = 8'h54; // T
        test_string[28] = 8'h45; // E
        test_string[29] = 8'h53; // S
        test_string[30] = 8'h54; // T
        test_string[31] = 8'h20; // space

        $display("------------------------------------------------------------------");
        $display("Starting 12-bit Dynamic Caesar Cipher Simulation");

        // Wait for FSM to leave IDLE after reset
        wait (fsm_state_out != S_IDLE_VAL) @(posedge clk);

        // --- Main Test Loop (NUM_BLOCKS blocks) ---
        for (block_index = 0; block_index < NUM_BLOCKS; block_index = block_index + 1) begin
            $display("\n--- Block %0d ---", block_index);

            // Wait for RX ready state
            wait (fsm_state_out == S_RX_WAIT_VAL) @(posedge clk);

            // Byte 0 (LSB). transmit_byte() only drives the waveform --
            // it does NOT itself wait on rx_data_ack, which is a
            // single-clock-cycle pulse on the DUT side. A testbench
            // `wait()` starting right as that pulse ends can miss it
            // entirely (a real race found by simulation, not
            // guessable from the report alone) -- synchronizing on
            // fsm_state_out instead is safe because it's a registered
            // signal that holds steady for many cycles, not a
            // transient pulse.
            $display("Sending Byte 0 (LSB): %h ('%c')", test_string[block_index*2], test_string[block_index*2]);
            transmit_byte(test_string[block_index*2]);
            wait (fsm_state_out == S_RX_BYTE0_VAL) @(posedge clk);

            // Byte 1 (MSB)
            $display("Sending Byte 1 (MSB): %h ('%c')", test_string[block_index*2+1], test_string[block_index*2+1]);
            transmit_byte(test_string[block_index*2+1]);

            // Wait for FSM to finish encrypt/decrypt/tx
            wait (fsm_state_out == S_IDLE_VAL) @(posedge clk);

            // Expected block computation
            expected_input_block[7:0]  = test_string[block_index*2];
            expected_input_block[11:8] = test_string[block_index*2+1][3:0];

            // Verify decrypted output
            captured_key[block_index]        = UUT.current_shift_key;
            captured_ciphertext[block_index] = UUT.debug_ciphertext;
            if (UUT.debug_decoded_data == expected_input_block) begin
                $display("SUCCESS: Decrypted Block %0d Matches Input.  (key=%h, ciphertext=%h)",
                         block_index, UUT.current_shift_key, UUT.debug_ciphertext);
                pass_count = pass_count + 1;
            end else begin
                $display("FAILURE: Block %0d Mismatch!", block_index);
                $display("  Expected Input (12-bit): %h", expected_input_block);
                $display("  Decoded Output (12-bit): %h", UUT.debug_decoded_data);
                $display("  Key Used: %h", UUT.current_shift_key);
                fail_count = fail_count + 1;
            end
        end

        // Correct decode/encode round-tripping alone doesn't prove the
        // key is actually *dynamic* -- encoder+decoder are exact
        // inverses for ANY fixed key, so a stuck/static key would
        // still pass every SUCCESS check above. Independently verify
        // the core claim ("a unique key for every encryption round")
        // by checking all NUM_BLOCKS captured keys are pairwise distinct.
        distinct_keys_ok = 1;
        for (key_check_i = 0; key_check_i < NUM_BLOCKS; key_check_i = key_check_i + 1) begin
            for (key_check_j = key_check_i + 1; key_check_j < NUM_BLOCKS; key_check_j = key_check_j + 1) begin
                if (captured_key[key_check_i] == captured_key[key_check_j]) begin
                    distinct_keys_ok = 0;
                end
            end
        end

        $write("\nKeys used per block:");
        for (report_i = 0; report_i < NUM_BLOCKS; report_i = report_i + 1)
            $write(" %h", captured_key[report_i]);
        $write("\nCiphertexts per block:");
        for (report_i = 0; report_i < NUM_BLOCKS; report_i = report_i + 1)
            $write(" %h", captured_ciphertext[report_i]);
        $display("");

        if (distinct_keys_ok)
            $display("DYNAMIC KEY CHECK: PASS (all %0d keys distinct)", NUM_BLOCKS);
        else begin
            $display("DYNAMIC KEY CHECK: FAIL (key repeated across blocks)");
            fail_count = fail_count + 1;
        end

        $display("\n------------------------------------------------------------------");
        $display("Simulation Complete. %0d/%0d blocks round-tripped correctly.", pass_count, NUM_BLOCKS);
        if (fail_count == 0)
            $display("TESTBENCH RESULT: PASS");
        else
            $display("TESTBENCH RESULT: FAIL");
        $display("------------------------------------------------------------------");

        #1000;
        $finish;
    end

    // --- 7. UART Transmission Task ---
    // Drives one 8N1 UART byte onto serial_rx and returns as soon as
    // the stop bit's hold time has elapsed. Deliberately does NOT wait
    // on rx_data_ack here -- that's a single-clock-cycle pulse on the
    // DUT side, and starting a `wait()` for it only after this task's
    // own fixed-length bit-timing sequence finishes is a real race:
    // if the DUT's ack pulse happens to land at (or just before) the
    // exact moment this task reaches the wait, it can come and go
    // before the wait ever starts watching, hanging forever. Callers
    // synchronize on the DUT's registered fsm_state_out instead, which
    // holds steady for many cycles and can't be missed this way.
    task transmit_byte;
        input [7:0] data_byte;
        integer bit_index;
        begin
            @(posedge clk);

            // Start Bit (0)
            serial_rx = 1'b0;
            #(`BAUD_DELAY);

            // Data Bits (8 bits LSB first)
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                serial_rx = data_byte[bit_index];
                #(`BAUD_DELAY);
            end

            // Stop Bit (1)
            serial_rx = 1'b1;
            #(`BAUD_DELAY);
        end
    endtask

endmodule
