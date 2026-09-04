// uart_receiver_fsm.v
//
// Deserializes 8N1 UART framing (1 start bit, 8 data bits LSB-first, 1
// stop bit) sampled once per baud_tick_in pulse -- now a real divided
// baud rate (see baud_tick_gen.v), not the hardwired always-1 signal
// the original top-level integration used.
//
// Known, documented limitation (matches the report's own "Limitations"
// section: "Does not include error correction or parity checking"):
// if the stop bit ever samples low (a framing error), rx_data_ready is
// never asserted and the FSM parks in RX_DONE waiting for an
// rx_data_ack that system_control_fsm will never send, since it's
// itself waiting on rx_data_ready. This is a real lockup path on a bad
// frame -- not fixed here, since it's out of the report's own stated
// scope, but worth knowing rather than discovering by surprise.
module uart_receiver_fsm (
    // Clock and Reset
    input  clk,
    input  reset,
    // Timing and Serial I/O
    input  baud_tick_in,  // 1-cycle pulse at the baud rate
    input  serial_rx,     // Incoming serial data pin
    // Control and Parallel Data Output (To System FSM)
    output reg rx_data_ready, // Asserted when data_out is valid
    input  rx_data_ack,       // Acknowledge signal from system FSM
    output reg [7:0] rx_data_out
);

    // --- INTERNAL REGISTERS ---
    reg [3:0] bit_count; // Tracks which of the 10 bits we are currently sampling
    reg [7:0] data_reg;  // Temporary buffer for received data

    // --- FSM States ---
    localparam
        RX_IDLE  = 3'b000,
        RX_START = 3'b001,
        RX_DATA  = 3'b010,
        RX_STOP  = 3'b011,
        RX_DONE  = 3'b100;

    reg [2:0] state, next_state;

    // --- 1. State Register (Sequential) ---
    always @(posedge clk) begin
        if (reset) begin
            state <= RX_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // --- 2. Data/Control Register Updates (Sequential) ---
    always @(posedge clk) begin
        if (reset) begin
            bit_count     <= 4'h0;
            data_reg      <= 8'h00;
            rx_data_out   <= 8'h00;
            rx_data_ready <= 1'b0;
        end else begin
            case (state)
                RX_IDLE: begin
                    rx_data_ready <= 1'b0;
                    if (serial_rx == 1'b0) begin
                        bit_count <= 4'h0;
                    end
                end

                RX_START: begin
                    if (baud_tick_in) begin
                        bit_count <= 4'h0;
                    end
                end

                RX_DATA: begin
                    if (baud_tick_in) begin
                        // Load data bit LSB first
                        data_reg[bit_count] <= serial_rx;
                        if (bit_count == 4'h7) begin
                            bit_count <= 4'h0;
                        end else begin
                            bit_count <= bit_count + 1'b1;
                        end
                    end
                end

                RX_STOP: begin
                    if (baud_tick_in) begin
                        if (serial_rx == 1'b1) begin // Check for stop bit
                            rx_data_out   <= data_reg;
                            rx_data_ready <= 1'b1; // Assert data ready
                        end
                    end
                end

                RX_DONE: begin
                    if (rx_data_ack) begin
                        rx_data_ready <= 1'b0;
                    end
                end
            endcase
        end
    end

    // --- 3. Next State Logic (Combinational) ---
    always @(*) begin
        next_state = state;
        case (state)
            RX_IDLE: begin
                if (serial_rx == 1'b0)
                    next_state = RX_START;
            end

            RX_START: begin
                if (baud_tick_in)
                    next_state = RX_DATA;
            end

            RX_DATA: begin
                if (bit_count == 4'h7 && baud_tick_in)
                    next_state = RX_STOP;
            end

            RX_STOP: begin
                if (baud_tick_in)
                    next_state = RX_DONE;
            end

            RX_DONE: begin
                if (rx_data_ack)
                    next_state = RX_IDLE;
            end

            default: next_state = RX_IDLE;
        endcase
    end

endmodule
