# Interview preparation

Questions an interviewer could reasonably ask about this project, with
where in the repo to find the real answer (not a generic textbook
answer). Only questions this specific implementation can actually
answer are included.

## LFSR design

**Why a 12-bit LFSR specifically?**
The report's own scope: it's the assignment's chosen key/state width.
12 bits also happens to match the block size used for the cipher itself
(two received UART bytes -> one 12-bit block), so the LFSR's full state
can be used directly as part of the working data width. See
[`rtl/crypto_encoder_block.v`](../rtl/crypto_encoder_block.v).

**What feedback polynomial/taps are used?**
`lfsr_state[11] ^ lfsr_state[5] ^ lfsr_state[3] ^ lfsr_state[0]`, fed
into bit 0 on a left shift (`{lfsr_state[10:0], feedback_bit}`) -- taps
at bit positions 11, 5, 3, 0.

**How do you know that tap set is actually maximal-length, rather than just claimed to be?**
It was measured, not assumed: [`tb/lfsr_period_test.v`](../tb/lfsr_period_test.v)
shifts the LFSR from its real seed and counts shifts until it returns to
the seed. Result: period 4095 = 2^12 - 1, confirmed maximal-length --
see [`docs/verification-log.md`](verification-log.md#additional-verification-is-the-lfsr-actually-maximal-length)
for the real run output. Worth mentioning in an interview: the *first*
version of that test reported an incorrect period (2048) because of a
same-time-step read/write race in the test itself, not the design --
caught by cross-checking against an independent model, which is
arguably the more interesting story than the number itself.

**Does the 4095-shift period mean the 8-bit key doesn't repeat for 4095 blocks?**
No -- and this is an easy claim to accidentally overstate. 4095 is the
period of the full 12-bit *state*. The cipher's key is only the low
byte of that state (`current_shift_key`), which has just 256 possible
values, so by pigeonhole it must repeat far sooner. Measured, not
assumed: `tb/lfsr_period_test.v` tracks every key value seen across the
full 4095-shift period and finds only 255 of the 256 possible values
ever appear, with the first repeat at shift 31 (key `0x0c`, first seen
at shift 6). The correct claim is "the LFSR state has a verified
maximal-length period of 4095" and, separately, "the key changes every
block, sourced from that maximal-length sequence" -- not "the key
doesn't repeat for 4095 blocks." An earlier draft of this repo's docs
conflated the two; worth mentioning that correction if asked, since
catching your own overstated claim is itself a useful signal.

**What happens if the LFSR reaches the all-zero state?**
With XOR-only feedback, state 0 feeds back 0 forever -- a real lock-up
state for this class of LFSR. This design never reaches it: the reset
value is `12'h001` and the seed is `12'h0A8` (both nonzero), and the
maximal-length property (see above) guarantees the cycle from a nonzero
seed visits every one of the 4095 nonzero states and never zero. The
key-derivation logic in `crypto_encoder_block.v` separately guards
against an all-zero *key* (forcing `shift_key_reg` to `8'h01` if it's
ever `8'h00`) -- a defensive check that in practice never triggers, but
would matter if the 12-bit LFSR value's low byte happened to be zero on
some visited state (which it validly can be without the full state
being zero).

## Dynamic key

**How is the dynamic key generated?**
The low 8 bits of the 12-bit LFSR state (`lfsr_state[7:0]`), shifted
once per 12-bit block by `system_control_fsm.v`'s `S_SHIFT_KEY` state.

**Why is the key actually dynamic here -- what would make you doubt it?**
Because encoder and decoder are exact mathematical inverses for *any*
fixed key, a testbench that only checks `decrypted == original` would
pass identically whether the key changes or not -- that's not proof of
dynamism. This project found that gap the hard way: an earlier version
of `system_control_fsm.v` reseeded the LFSR every block (a real bug,
not hypothetical), producing a static `0x50` key on every block while
every round-trip check still passed. See Bug 4 in
[`docs/verification-log.md`](verification-log.md#bug-4-the-dynamic-key-wasnt-actually-dynamic).

**How was dynamic-key behavior actually verified, then?**
[`tb/top_system_testbench.v`](../tb/top_system_testbench.v) explicitly
captures the key used for each of the 16 blocks and checks all 16 are
pairwise distinct, independent of whether decryption succeeded.

## Caesar cipher

**Why use a Caesar cipher at all, given it's a well-known weak cipher?**
The project's actual point isn't cipher strength -- it's demonstrating
FSM-based hardware design, UART integration, and a hardware-generated
dynamic key source, using the simplest possible cipher so the crypto
logic itself doesn't dominate the design. Caesar cipher here is
addition/subtraction mod 4096 (`crypto_encoder_block.v` /
`crypto_decoder_block.v`), not lookup-table substitution.

**Why is it still insecure even with a dynamic key?**
Each key is just the previous LFSR state shifted by one bit, so
consecutive keys are strongly correlated (an LFSR is a known-plaintext-
recoverable pseudorandom source, not cryptographically secure). Stated
directly in [`docs/verification-log.md`](verification-log.md#what-this-does-and-doesnt-prove)'s
limitations. It's a teaching-lab demonstration of the dynamic-key
*concept*, not a real cipher.

## UART

**How does UART framing work in this design?**
8N1: 1 start bit (low), 8 data bits LSB-first, 1 stop bit (high) --
implemented in [`rtl/uart_receiver_fsm.v`](../rtl/uart_receiver_fsm.v)
and [`rtl/uart_transmitter_fsm.v`](../rtl/uart_transmitter_fsm.v).

**Why 115200 baud?**
A standard, common UART baud rate, parameterized (not hardwired) in
[`rtl/baud_tick_gen.v`](../rtl/baud_tick_gen.v) as `BAUD_RATE`, alongside
`CLK_FREQ_HZ` (50 MHz, the report's stated target frequency). Both are
module parameters, not code, so they could be reconfigured for a
different clock or link speed without touching any logic.

**How does the receiver determine a byte boundary?**
It idles sampling `serial_rx`; a falling edge (`serial_rx == 1'b0`)
while idle is interpreted as a start bit and moves the FSM to
`RX_START`, which then samples 8 data bits and a stop bit at
`baud_tick_in` pulses (`RX_IDLE -> RX_START -> RX_DATA -> RX_STOP ->
RX_DONE`). See the state machine in `uart_receiver_fsm.v`.

**What was the real baud-rate bug, and why did it matter?**
The original report's appendix hardwired `baud_tick = 1'b1` (permanently
high), so both UART FSMs advanced one bit per clock edge -- 50 Mbps at
50 MHz, not 115200 baud -- while the report's own text claimed "baud
rate accuracy" was verified. Fixed with a real counter-based divider.
See Bug 1 in [`docs/verification-log.md`](verification-log.md#bug-1-no-real-baud-rate-generator-found-by-static-review-confirmed-real).

**What happens on a UART framing error (bad stop bit)?**
A known, undefended lockup: if the sampled stop bit isn't high,
`rx_data_ready` is never asserted, so `system_control_fsm.v` waits
forever for a byte that will never be acknowledged as arrived. This
matches the original report's own stated scope ("does not include error
correction or parity checking") -- not fixed here, but explicitly
documented rather than silently left as a surprise. See
[`rtl/uart_receiver_fsm.v`](../rtl/uart_receiver_fsm.v)'s header comment.

## Verification methodology

**How was encryption/decryption correctness verified?**
[`tb/top_system_testbench.v`](../tb/top_system_testbench.v) drives 32
real bytes ("GEMINI DYNAMIC LFSR CIPHER TEST ") through the real UART
RX -> encrypt -> decrypt -> UART TX pipeline (16 blocks of 12 bits
each) and checks the decrypted output against the known input for
every block.

**Describe a real bug you found and how you diagnosed it.**
The `rx_data_ready` handshake race (Bug 2 in
[`docs/verification-log.md`](verification-log.md#bug-2-rx_data_ready-double-consumption-race-found-only-by-simulating)):
`rx_data_ready` is held high for 2 clock cycles by the receiver, but
`system_control_fsm.v` originally sampled it as a raw level in two
consecutive states, so a single byte-arrival event was consumed twice.
Diagnosed with a `+DEBUG_TRACE`-gated `$monitor` signal trace (see
`sim/run.sh --trace`), fixed with rising-edge detection
(`rx_data_ready_pulse = rx_data_ready & ~rx_data_ready_d`).

**Was there ever a bug in the testbench itself, separate from the RTL?**
Twice, in fact. `top_system_testbench.v`'s original `transmit_byte` task
waited on `rx_data_ack`'s single-cycle pulse after its own fixed bit-
timing sequence finished, which could start watching after the pulse had
already come and gone (Bug 3). And the standalone LFSR test's first
version read `UUT.lfsr_state` in the same simulation time step the DUT
updates it, racing the non-blocking assignment (see the LFSR section
above). Both are real examples of verification code needing its own
correctness discipline, not just the design under test.

## Synthesis / hardware

**What would you do to actually synthesize this on an FPGA?**
Not attempted in this repo (see the README's Status table for why --
no Xilinx/FPGA toolchain available in this environment). The design is
plain synthesizable Verilog (no simulation-only constructs in the RTL
itself, though the testbench uses `$display`/`$monitor`/`$dumpfile`
which are simulation-only and already isolated in `tb/`), so the next
step would be a synthesis run in Vivado/Xilinx ISE targeting whatever
part the lab specifies, driven by the same `rtl/*.v` file list already
used by `sim/run.sh`.

**What FPGA resources would you expect this to use?**
Small: this design has no multipliers, no block RAM, and no wide
arithmetic -- flip-flops for the FSM states, the 12-bit LFSR, and the
UART bit/byte counters, plus LUTs for the small combinational adders
(12-bit) and next-state logic. Expect low-single-digit-percent
utilization on any mainstream FPGA; the actual numbers would only be
known after a real synthesis report, not claimed here.

**What timing constraints would matter?**
A single clock domain (50 MHz, per `CLK_FREQ_HZ`) drives everything --
no cross-clock-domain synchronization is needed internally. The real
constraints would be: the clock period itself (meeting setup/hold at
50 MHz for the largest combinational path, likely the 12-bit adder or
the next-state FSM logic), and I/O timing on `serial_rx`/`serial_tx` if
connected to a real external UART transceiver, since those are
asynchronous inputs to this synchronous design.

## Design improvement

**What would you improve in the next version?**
In priority order, matched to the limitations actually documented in
[`docs/verification-log.md`](verification-log.md#what-this-does-and-doesnt-prove):
1. Framing-error handling (a timeout or re-sync path out of `RX_DONE`
   instead of an undefended lockup on a bad stop bit).
2. Real FPGA synthesis + hardware bring-up, to validate timing and I/O
   behavior beyond simulation.
3. A less-correlated key source (the current key is one LFSR shift away
   from the previous key -- a stronger construction would decouple
   consecutive keys more thoroughly, even while keeping the design
   simple).
4. Configurable/negotiated baud rate instead of a compile-time
   parameter, if this were to talk to a real, less-controlled UART peer.
