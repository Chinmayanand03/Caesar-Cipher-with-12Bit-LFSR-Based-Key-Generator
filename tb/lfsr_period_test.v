// lfsr_period_test.v
//
// Standalone verification of the 12-bit LFSR inside crypto_encoder_block.v,
// independent of the UART/system-level testbench. The system-level
// testbench (top_system_testbench.v) only ever observes 4 shifts of the
// LFSR (one per 12-bit block) -- enough to prove the key changes block to
// block, but not enough to say anything about the LFSR's period or its
// behavior over its full state space.
//
// This test drives lfsr_shift_en for up to 5000 cycles after the real
// seed load (12'h0A8, matching system_control_fsm.v's one-time seed) and
// checks, by directly observing the internal lfsr_state register
// (hierarchical reference, the same technique top_system_testbench.v
// already uses for UUT.rx_data_ready/UUT.current_shift_key):
//   1. The LFSR never lands on the all-zero state (the classic LFSR
//      lock-up: with XOR-only feedback, state 0 feeds back 0 forever).
//   2. Its period -- how many shifts until it returns to the seed state.
//      A true maximal-length 12-bit LFSR has period 2^12 - 1 = 4095.
//   3. The 8-bit *key* (current_shift_key, the low byte of the 12-bit
//      state) is a different, smaller-period question from (2): a
//      12-bit maximal-length sequence guarantees the *state* doesn't
//      repeat for 4095 shifts, but the 8-bit key has only 256 possible
//      values, so by simple pigeonhole it must repeat far sooner than
//      that. This test tracks the first shift at which a key value
//      repeats and how many of the 256 possible key values are ever
//      seen, so the README/docs can state the real number instead of
//      assuming "12-bit period" implies "8-bit key doesn't repeat."
//
// This does not assume the taps {11,5,3,0} give a maximal-length
// sequence -- it measures the actual period by simulation.
`timescale 1ns/1ps

module lfsr_period_test;

    reg clk, reset, lfsr_shift_en, lfsr_load_seed;
    reg [11:0] plaintext_in;
    wire [11:0] ciphertext_out;
    wire [7:0] current_shift_key;

    integer shift_count;
    integer period;
    integer zero_hits;
    reg [11:0] seed_state;
    reg period_found;

    // Key-repeat tracking (see header comment, point 3). first_seen_shift[k]
    // is the shift index key value k was first observed at, or -1 if never
    // seen -- lets us report both how many distinct key values appear over
    // the full period, and exactly when the first repeat happens.
    integer first_seen_shift [0:255];
    integer distinct_key_count;
    integer key_check_idx;
    reg first_key_repeat_found;
    integer first_key_repeat_shift;
    reg [7:0] first_key_repeat_value;

    crypto_encoder_block UUT (
        .clk(clk),
        .reset(reset),
        .lfsr_shift_en(lfsr_shift_en),
        .lfsr_load_seed(lfsr_load_seed),
        .plaintext_in(plaintext_in),
        .ciphertext_out(ciphertext_out),
        .current_shift_key(current_shift_key)
    );

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    initial begin
        reset = 1'b1;
        lfsr_shift_en = 1'b0;
        lfsr_load_seed = 1'b0;
        plaintext_in = 12'h000;
        zero_hits = 0;
        period = -1;
        period_found = 1'b0;
        distinct_key_count = 0;
        first_key_repeat_found = 1'b0;
        first_key_repeat_shift = -1;
        for (key_check_idx = 0; key_check_idx < 256; key_check_idx = key_check_idx + 1) begin
            first_seen_shift[key_check_idx] = -1;
        end

        @(negedge clk); @(negedge clk);
        reset = 1'b0;

        // Real one-time seed load, matching system_control_fsm.v's usage.
        // Stimulus is changed on negedge and lfsr_state is only ever read
        // on a later negedge, so every read happens strictly after the
        // intervening posedge's non-blocking update has settled -- this
        // avoids a same-time-step read-before-write race against the
        // DUT's `lfsr_state <= ...` (an earlier version of this test read
        // UUT.lfsr_state immediately after @(posedge clk), which can race
        // the DUT's own posedge-triggered update and silently read the
        // pre-update value; that bug produced a false "period = 2048"
        // reading here, contradicted by an independent model of the same
        // recurrence -- fixed by moving all sampling to negedge).
        @(negedge clk);
        lfsr_load_seed = 1'b1;
        @(negedge clk);
        lfsr_load_seed = 1'b0;
        seed_state = UUT.lfsr_state;
        $display("------------------------------------------------------------------");
        $display("LFSR standalone period/lock-up test");
        $display("Seed state: %h", seed_state);

        if (seed_state == 12'h000) begin
            $display("FAIL: seed itself is the all-zero state");
            $finish;
        end

        // Record the seed's own key value before any shifts, so the
        // key-repeat tracking below covers the full sequence including
        // shift 0.
        first_seen_shift[current_shift_key] = 0;

        // Shift up to 5000 times (> 4095, the maximal period for a 12-bit
        // LFSR) and watch for a zero state or a return to the seed. Also
        // track the 8-bit key value at every shift (see header comment,
        // point 3) -- current_shift_key is a continuous combinational
        // output, safe to sample at negedge alongside lfsr_state.
        for (shift_count = 1; shift_count <= 5000 && !period_found; shift_count = shift_count + 1) begin
            @(negedge clk);
            lfsr_shift_en = 1'b1;
            @(negedge clk);
            lfsr_shift_en = 1'b0;

            if (UUT.lfsr_state == 12'h000) begin
                zero_hits = zero_hits + 1;
            end
            if (UUT.lfsr_state == seed_state) begin
                period = shift_count;
                period_found = 1'b1;
            end

            if (first_seen_shift[current_shift_key] != -1 && !first_key_repeat_found) begin
                first_key_repeat_found = 1'b1;
                first_key_repeat_shift = shift_count;
                first_key_repeat_value = current_shift_key;
            end else if (first_seen_shift[current_shift_key] == -1) begin
                first_seen_shift[current_shift_key] = shift_count;
            end
        end

        for (key_check_idx = 0; key_check_idx < 256; key_check_idx = key_check_idx + 1) begin
            if (first_seen_shift[key_check_idx] != -1)
                distinct_key_count = distinct_key_count + 1;
        end

        $display("Shifts executed: %0d", shift_count - 1);
        $display("All-zero state visits: %0d", zero_hits);
        if (period_found)
            $display("Period (shifts to return to seed): %0d", period);
        else
            $display("Period: NOT FOUND within %0d shifts (no repeat observed)", shift_count - 1);

        if (zero_hits != 0)
            $display("LOCK-UP CHECK: FAIL (LFSR reached the all-zero state %0d time(s))", zero_hits);
        else
            $display("LOCK-UP CHECK: PASS (all-zero state never reached)");

        if (period_found && period == 4095)
            $display("MAXIMAL-LENGTH CHECK: PASS (period = 4095 = 2^12 - 1, confirmed maximal-length)");
        else if (period_found)
            $display("MAXIMAL-LENGTH CHECK: FAIL (period = %0d, not maximal-length)", period);
        else
            $display("MAXIMAL-LENGTH CHECK: FAIL (no repeat within 5000 shifts)");

        // The 12-bit *state* not repeating for 4095 shifts does NOT mean
        // the 8-bit *key* doesn't repeat -- it has only 256 possible
        // values, so it must repeat far sooner. Reported here so this
        // claim is backed by a real run, not assumed from the state
        // period above.
        $display("Distinct 8-bit key values seen over full period: %0d (max possible: 256)", distinct_key_count);
        if (first_key_repeat_found)
            $display("First repeated key value: %h (first seen at shift %0d, repeated at shift %0d)",
                     first_key_repeat_value, first_seen_shift[first_key_repeat_value], first_key_repeat_shift);

        if (zero_hits == 0 && period_found && period == 4095)
            $display("\nTESTBENCH RESULT: PASS");
        else
            $display("\nTESTBENCH RESULT: FAIL");
        $display("------------------------------------------------------------------");

        $finish;
    end

endmodule
