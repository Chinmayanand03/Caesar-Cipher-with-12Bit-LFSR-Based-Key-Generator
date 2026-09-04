// uart_transmitter_fsm.v
//
// Serializes an 8-bit byte as 8N1 UART framing (start bit low, 8 data
// bits LSB-first, stop bit high), paced by baud_tick_in -- now a real
// divided baud rate (see baud_tick_gen.v).
module uart_transmitter_fsm (
    // Clock and Reset
    input  clk,
    input  reset,
    // Timing and Serial I/O
    input  baud_tick_in,   // 1-cycle pulse at the baud rate
    output reg serial_tx,  // Outgoing serial data pin
    // Control and Parallel Data Input (From System FSM)
    input  [7:0] tx_data_in,
    input  tx_start_command, // Command to begin transmission
    output reg tx_busy       // Asserted when transmission is active
);

    // --- INTERNAL REGISTERS ---
    reg [3:0] bit_count;   // Tracks which of the 10 bits we are currently sending
    reg [7:0] tx_data_reg; // Data buffer

    // --- FSM States ---
    localparam
        TX_IDLE  = 3'b000,
        TX_START = 3'b001,
        TX_DATA  = 3'b010,
        TX_STOP  = 3'b011;

    reg [2:0] state, next_state;

    // --- 1. State Register (Sequential) ---
    always @(posedge clk) begin
        if (reset) begin
            state <= TX_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // --- 2. Data/Control Register Updates (Sequential) ---
    always @(posedge clk) begin
        if (reset) begin
            serial_tx <= 1'b1; // Idle state is high
            tx_busy   <= 1'b0;
            bit_count <= 4'h0;
        end else begin
            case (state)
                TX_IDLE: begin
                    if (tx_start_command) begin
                        tx_busy     <= 1'b1;
                        tx_data_reg <= tx_data_in;
                    end
                end

                TX_START: begin
                    if (baud_tick_in) begin
                        // Start bit sent, prepare data bits
                        serial_tx <= tx_data_reg[0];
                        bit_count <= 4'h1;
                    end else begin
                        serial_tx <= 1'b0; // Send start bit
                    end
                end

                TX_DATA: begin
                    if (baud_tick_in) begin
                        if (bit_count < 4'h8) begin
                            // Send next data bit (LSB first)
                            serial_tx <= tx_data_reg[bit_count];
                            bit_count <= bit_count + 1'b1;
                        end
                    end
                end

                TX_STOP: begin
                    if (baud_tick_in) begin
                        serial_tx <= 1'b1; // Send stop bit (High)
                        tx_busy   <= 1'b0;
                    end
                end
            endcase
        end
    end

    // --- 3. Next State Logic (Combinational) ---
    always @(*) begin
        next_state = state;

        case (state)
            TX_IDLE: begin
                if (tx_start_command)
                    next_state = TX_START;
            end

            TX_START: begin
                if (baud_tick_in)
                    next_state = TX_DATA;
            end

            TX_DATA: begin
                if (bit_count == 4'h8 && baud_tick_in)
                    next_state = TX_STOP;
            end

            TX_STOP: begin
                if (baud_tick_in)
                    next_state = TX_IDLE; // Done, return to idle
            end

            default: next_state = TX_IDLE;
        endcase
    end

endmodule
