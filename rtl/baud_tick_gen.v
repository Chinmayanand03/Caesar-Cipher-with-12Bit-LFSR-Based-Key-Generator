// baud_tick_gen.v
//
// Real baud-rate tick generator. The original report/appendix tied
// baud_tick permanently high in top_system_integration.v ("Simulation-
// Only Timing... connect the baud tick to the fixed 1'b1 value for
// simulation simplicity"), which meant the UART FSMs advanced one bit
// per clock edge -- 50 Mbps at the stated 50 MHz target, not any real
// UART baud rate. That directly contradicted the report's own claim
// (Section 5) that "baud rate accuracy" was verified: there was
// nothing dividing the clock, so nothing to be accurate about.
//
// This module actually divides clk down to a single-cycle pulse at
// BAUD_RATE, which is what uart_receiver_fsm.v's own port comment
// ("1-cycle pulse at the baud rate") always assumed baud_tick_in would
// be.
module baud_tick_gen #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BAUD_RATE   = 115_200
) (
    input  wire clk,
    input  wire reset,
    output reg  baud_tick
);

    // Integer division is intentional: DIVISOR is a compile-time
    // constant, and any rounding error here is the same kind of
    // baud-rate tolerance every real UART clock divider has.
    localparam integer DIVISOR = CLK_FREQ_HZ / BAUD_RATE;

    // Enough bits to count up to DIVISOR-1.
    localparam integer COUNTER_WIDTH = $clog2(DIVISOR);

    reg [COUNTER_WIDTH-1:0] count;

    always @(posedge clk) begin
        if (reset) begin
            count     <= {COUNTER_WIDTH{1'b0}};
            baud_tick <= 1'b0;
        end else if (count == DIVISOR - 1) begin
            count     <= {COUNTER_WIDTH{1'b0}};
            baud_tick <= 1'b1;
        end else begin
            count     <= count + 1'b1;
            baud_tick <= 1'b0;
        end
    end

endmodule
