# Verification log

This is a real record of actually simulating this design with
[Icarus Verilog](http://iverilog.icarus.com/) (`iverilog`/`vvp`,
v12.0), not a description of expected behavior. It documents four real
bugs found this way -- none of which were fixable from reading the
original report alone, since they only manifest during actual
execution.

The starting point was
[`docs/CaesarCipher_LFSR_12Bit report.pdf`](CaesarCipher_LFSR_12Bit%20report.pdf),
the original project report for **21ECC311L -- VLSI Design
Laboratory**. Its own Testing/Results sections describe a full
simulation pass in Xilinx ISE/ModelSim (`GEMINI`, `ECE`, `HELLO` test
strings, all reported correct). Reconstructing and re-running the
design surfaced two things the original write-up didn't catch: a
timing claim that didn't match the actual RTL, and a functional bug
that made the cipher's core "dynamic key" claim silently false while
every reported test still appeared to pass.

## How to reproduce this yourself

```bash
sim/run.sh             # system-level test: compile + run
sim/run.sh --trace     # same, plus a per-cycle signal trace
sim/run.sh --lfsr-test # standalone LFSR period / lock-up test
```
Needs `iverilog`/`vvp` on `PATH` (this repo was verified against
Icarus Verilog v12.0, `s20150603-1539-g2693dd32b`).

## Verification summary

Two independent testbenches, each targeting a different claim:

| Test | What it checks | How |
|---|---|---|
| `tb/top_system_testbench.v` | System-level correctness: UART framing, byte assembly, encryption, decryption, round-trip data integrity | Drives 32 real bytes ("GEMINI DYNAMIC LFSR CIPHER TEST ") through the real UART RX -> encrypt -> decrypt -> UART TX pipeline (16 blocks), compares decrypted output to known input |
| `tb/top_system_testbench.v` | Dynamic-key claim specifically | Captures the actual key used per block and checks all 16 are pairwise distinct (independent of round-trip success, which alone can't distinguish a dynamic key from a static one) |
| `tb/lfsr_period_test.v` | LFSR maximal-length property, lock-up avoidance, and the 8-bit key's real repeat point | Shifts the LFSR from its real seed up to 5000 times, measures the exact shift count to return to the seed, checks for any all-zero visits, and tracks every 8-bit key value seen |

### Test cases and results

| Test | Expected Result | Actual Result | Status |
|---|---|---|---|
| 16-block round-trip ("GEMINI DYNAMIC LFSR CIPHER TEST ") | decoded == input for every block | 16/16 blocks matched | PASS |
| Dynamic-key distinctness (16 blocks) | all 16 keys pairwise distinct | `50 a0 41 83 06 0c 18 31 63 c6 8c 19 32 65 cb 97` -- all distinct | PASS |
| LFSR all-zero lock-up | state never reaches `12'h000` | 0 zero-state visits in 4095 shifts | PASS |
| LFSR maximal-length | period == 4095 (2^12 - 1) | period == 4095, confirmed | PASS |
| 8-bit key repeat point (distinct from state period above) | measure, don't assume, when the key first repeats | 255/256 possible key values seen over the full period; first repeat at shift 31 (key `0x0c`) | Measured (see note below) |
| RTL simulation (Icarus Verilog) | compiles and runs to completion | compiles and runs, both testbenches | PASS |
| FPGA synthesis | -- | **Not attempted** -- no Xilinx/FPGA toolchain in this environment | Not attempted |
| FPGA implementation (place & route) | -- | **Not attempted** -- depends on synthesis above | Not attempted |
| Physical hardware testing | -- | **Not attempted** -- simulation only, no board available | Not attempted |
| ModelSim / Xilinx ISE simulation | -- | **Not run here** -- the original report's own ISim/ModelSim screenshots are in the source PDF; this repo's verification is an independent Icarus Verilog run | Not run in this repo |

The "8-bit key repeat point" row isn't a pass/fail test -- it's a
measurement that exists specifically to prevent a real misreading of
the maximal-length result above it: a 4095-shift *state* period does
not mean the 8-bit key avoids repeating for 4095 blocks (see
"Additional verification" below).

### Simulation evidence

Real, current output from `sim/run.sh` (re-run and captured for this
document, not illustrative):

```
------------------------------------------------------------------
Starting 12-bit Dynamic Caesar Cipher Simulation

--- Block 0 ---
Sending Byte 0 (LSB): 47 ('G')
Sending Byte 1 (MSB): 45 ('E')
SUCCESS: Decrypted Block 0 Matches Input.  (key=50, ciphertext=597)
...
Keys used per block: 50 a0 41 83 06 0c 18 31 63 c6 8c 19 32 65 cb 97
Ciphertexts per block: 597 9ed 98f 4a3 e5f d4d 361 c51 3a9 118 9cf 869 277 485 410 0eb
DYNAMIC KEY CHECK: PASS (all 16 keys distinct)

------------------------------------------------------------------
Simulation Complete. 16/16 blocks round-tripped correctly.
TESTBENCH RESULT: PASS
------------------------------------------------------------------
```

And from `sim/run.sh --lfsr-test`:

```
------------------------------------------------------------------
LFSR standalone period/lock-up test
Seed state: 0a8
Shifts executed: 4095
All-zero state visits: 0
Period (shifts to return to seed): 4095
LOCK-UP CHECK: PASS (all-zero state never reached)
MAXIMAL-LENGTH CHECK: PASS (period = 4095 = 2^12 - 1, confirmed maximal-length)
Distinct 8-bit key values seen over full period: 255 (max possible: 256)
First repeated key value: 0c (first seen at shift 6, repeated at shift 31)

TESTBENCH RESULT: PASS
------------------------------------------------------------------
```

## Bug 1: no real baud-rate generator (found by static review, confirmed real)

**Where**: the report's `top_system_integration.v` appendix.

**The claim**: Section 5 ("Testing and Evaluation") states the UART
FSMs were *"verified for correct start/stop bit handling, baud rate
accuracy, and stable timing synchronization."*

**What the code actually did**:
```verilog
// --- 1. BAUDRATE GENERATOR (Simulation-Only Timing) ---
assign baud_tick = 1'b1;
```
`baud_tick` was tied permanently high. Both UART FSMs sample/shift one
bit per clock edge -- i.e. 50 Mbps at the stated 50 MHz target, not
any real divided UART baud rate. There was nothing dividing the clock,
so nothing for "baud rate accuracy" to actually mean.

**Fix**: [`rtl/baud_tick_gen.v`](../rtl/baud_tick_gen.v), a real
counter-based divider (`CLK_FREQ_HZ / BAUD_RATE`, defaulting to
50 MHz / 115200 baud = a 434-cycle period), instantiated in
`top_system_integration.v` in place of the hardwired assignment.

## Bug 2: `rx_data_ready` double-consumption race (found only by simulating)

This one was invisible until Bug 1 was fixed and the design actually
ran at a real, multi-cycle-per-bit baud rate -- with `baud_tick`
hardwired to 1, every state transition happened every single cycle,
which structurally couldn't expose a signal that's held for *more*
than one cycle.

**Symptom**: with the real baud generator in place, the first block
("GE" -> block 0) still decoded correctly, but the simulation
deadlocked partway through block 1, never completing.

**Root cause**, found from a real signal trace
(`sim/run.sh --trace`): `uart_receiver_fsm`'s `rx_data_ready` is a
*level* held high for two clock cycles -- one for `rx_data_ack` to
register, one more for the receiver's own registered clear to take
effect. `system_control_fsm`'s `S_RX_WAIT` and `S_RX_BYTE0` states
each sampled that raw level combinationally, one cycle apart. The
result: the *same* single byte-arrival event satisfied both states'
"a byte arrived" check, so the FSM advanced past `S_RX_BYTE0` --
re-asserting `rx_data_ack` a second time -- without ever waiting for
byte 1 to actually arrive on the wire.

Block 0 still "passed" purely by coincidence: the 12-bit
byte-assembly index in `top_system_integration.v` toggles 0/1/0/1
independently of which logical block the FSM *thinks* it's on, so the
real second byte (received later, while the FSM was busy transmitting
what it believed was a complete block) landed in the right buffer slot
by luck of parity. That coincidence couldn't hold across a second
block, which is exactly where it deadlocked.

**Fix**: real rising-edge detection on `rx_data_ready`
(`rx_data_ready_pulse` in `system_control_fsm.v`) instead of sampling
the raw level, so each state consumes exactly one genuinely new byte
arrival, regardless of how long the underlying level stays asserted.

## Bug 3: a race in the testbench itself, not the design

After fixing Bug 2, the *first* byte of *every* block started hanging
instead.

**Root cause**: `top_system_testbench.v`'s `transmit_byte` task ended
by waiting for `rx_data_ack`'s pulse (`wait (rx_data_ack == 1) ...`) --
but `rx_data_ack` is only asserted for a single clock cycle, and the
task's own fixed bit-timing delay chain (10 bits x the real baud
period) finishes at almost exactly the same simulated moment the DUT's
ack pulse comes and goes, since both derive from the same baud timing.
If the task reached its `wait` after the pulse had already ended, it
would sit there forever waiting for a pulse that was never coming
again.

**Fix**: `transmit_byte` now only drives the waveform and returns; the
main test loop synchronizes on `fsm_state_out` instead (a registered
signal that holds steady for many cycles, not a one-cycle pulse that
can be missed by an external observer starting late).

## Bug 4: the "dynamic" key wasn't actually dynamic

This is the most significant finding. Bugs 1-3 were needed just to get
a real simulation running to completion at all; this one was only
found by explicitly checking a property the original report's own
testbench never checked.

**The claim**: the whole point of the project, stated in the Abstract,
Motivation, and Objectives -- *"a 12-bit LFSR ... produces a sequence
of pseudorandom bits that act as a varying shift key for each
encryption cycle."*

**What the original testbench actually verified**: only that
`decrypted_output == original_input` for each block. That's true for
*any* fixed key, correct or not -- encoder and decoder are exact
mathematical inverses regardless of what the key's value is. Passing
that check alone can't distinguish a genuinely dynamic key from a
completely static one.

**Root cause**: `system_control_fsm`'s `S_IDLE` state unconditionally
asserted `lfsr_load_seed` every time the FSM passed through it -- and
it passes through `S_IDLE` once *per block*, not just once at startup
(`...->S_TX_WAIT_FINAL->S_IDLE->S_LOAD_SEED->S_RX_WAIT->...` repeats
every block). That reseeds the LFSR back to the fixed value `12'h0A8`
before every single block, so it only ever advances by exactly one
shift from the same starting point every time. Confirmed directly: an
explicit per-block key check
```
Keys used per block: 50 50 50 50
DYNAMIC KEY CHECK: FAIL (key repeated across blocks)
```
every block used the identical key, `0x50` -- a static Caesar cipher
in practice, despite the design and report both describing (and
apparently intending) a dynamic one.

**Fix**: a `seeded` latch in `system_control_fsm.v`, set on the real
first pass through `S_LOAD_SEED` after reset, gating `S_IDLE`'s
`lfsr_load_seed` assertion to that one occurrence only. Every later
visit to `S_IDLE` (end of each subsequent block) now leaves the LFSR's
running state alone, so `lfsr_shift_en` in `S_SHIFT_KEY` genuinely
advances it block over block. Re-verified:
```
Keys used per block: 50 a0 41 83
DYNAMIC KEY CHECK: PASS (all 4 keys distinct)
```

## Final verified result

The narrative above (Bugs 1-4) describes the original 4-block/8-byte
("GEMINI  ") test that was actually running at the time each bug was
found and fixed -- left as-is since it's an accurate record of what was
run during that debugging session, not rewritten after the fact.

`tb/top_system_testbench.v` was later widened to 16 blocks / 32 bytes
("GEMINI DYNAMIC LFSR CIPHER TEST ") for broader real-traffic coverage.
Current real output:

```
Keys used per block: 50 a0 41 83 06 0c 18 31 63 c6 8c 19 32 65 cb 97
Ciphertexts per block: 597 9ed 98f 4a3 e5f d4d 361 c51 3a9 118 9cf 869 277 485 410 0eb
DYNAMIC KEY CHECK: PASS (all 16 keys distinct)

Simulation Complete. 16/16 blocks round-tripped correctly.
TESTBENCH RESULT: PASS
```
Reproduced across multiple independent runs (deterministic -- no
randomness anywhere in this design, so every run should and does
produce identical output). The 16 keys above are the same LFSR sequence
as `tb/lfsr_period_test.v`'s first 16 shifts from the same seed --
consistent across both testbenches, as expected for a design with no
randomness.

## Additional verification: is the LFSR actually maximal-length?

The system-level testbench above only ever shifts the LFSR 16 times
(once per 12-bit block, and only 4 times before it was widened -- see
above), which is enough to show the key changes block to block but says
nothing about the LFSR's period, whether it can ever lock up at the
all-zero state, or how the 8-bit *key* (only the low byte of the 12-bit
state) behaves over that period. `crypto_encoder_block.v`'s
own comment claims taps `{11,5,3,0}` are "the standard primitive-
polynomial tap set for a 12-bit Fibonacci LFSR" -- a claim worth
actually checking rather than taking on faith.

**Test**: [`tb/lfsr_period_test.v`](../tb/lfsr_period_test.v), run via
`sim/run.sh --lfsr-test`. It instantiates `crypto_encoder_block`
standalone, loads the real seed (`12'h0A8`), then shifts it up to 5000
times, checking after every shift whether the state has returned to the
seed (period) or landed on `12'h000` (lock-up).

**First run produced a wrong answer -- from the test, not the RTL.**
The first version of this test read `UUT.lfsr_state` immediately after
`@(posedge clk)`, in the same simulation time step as the DUT's own
`lfsr_state <= ...` (a non-blocking assignment). Icarus Verilog's
scheduling for that case is a same-time-step read-before-write race:
the read can observe the *pre*-update value. That version reported a
period of 2048 -- silently wrong, not a real property of the design.
Cross-checked against an independent JavaScript model of the exact same
feedback recurrence (`lfsr_state[11]^lfsr_state[5]^lfsr_state[3]^lfsr_state[0]`,
shift-left-with-feedback-into-bit-0), which found the true period is
4095 with all 4095 nonzero states forming a single cycle -- confirming
the first Verilog result was a testbench bug, not an RTL one. Fixed by
sampling `lfsr_state` only on `@(negedge clk)`, strictly after the
intervening posedge's update has settled, and re-ran:

```
------------------------------------------------------------------
LFSR standalone period/lock-up test
Seed state: 0a8
Shifts executed: 4095
All-zero state visits: 0
Period (shifts to return to seed): 4095
LOCK-UP CHECK: PASS (all-zero state never reached)
MAXIMAL-LENGTH CHECK: PASS (period = 4095 = 2^12 - 1, confirmed maximal-length)
Distinct 8-bit key values seen over full period: 255 (max possible: 256)
First repeated key value: 0c (first seen at shift 6, repeated at shift 31)

TESTBENCH RESULT: PASS
------------------------------------------------------------------
```

Reproduced across multiple runs (deterministic, as expected for a
design with no randomness). **Confirmed**: taps `{11,5,3,0}` genuinely
give a maximal-length 12-bit LFSR (period 2^12 - 1 = 4095, every nonzero
state visited exactly once per cycle), and the all-zero lock-up state is
never reached from this seed -- the RTL comment's claim holds, verified
rather than assumed.

**A second, easy-to-get-wrong claim, checked in the same run rather
than assumed:** the 4095-shift *state* period does not mean the 8-bit
*key* avoids repeating for 4095 blocks. The key is only the low byte of
the state (256 possible values), so by pigeonhole it must repeat far
sooner -- confirmed above: only 255 of the 256 possible key values ever
appear across the full period, and the first repeated key value
(`0x0c`) shows up at shift 31, not after thousands of shifts. An
earlier draft of this document (and of `crypto_encoder_block.v`'s own
header comment) described the 4095-state period as if it also bounded
how often the *key* repeats, which conflates the two and overstates the
design's dynamic-key strength -- corrected here and in the RTL comment
once this was actually measured instead of assumed.

This is also a useful, honest data point on its own: even a small,
purpose-built verification testbench can have its own timing bugs
independent of the design under test, which is exactly why the fix
above (cross-checking against an independent model, not just trusting
the first simulation run) mattered.

## What this does and doesn't prove

**Proves**: the RTL, as fixed, genuinely encrypts and decrypts 16
back-to-back 12-bit blocks correctly over a real (115200 baud) UART
link, using a real 12-bit LFSR that produces a different 8-bit key
every block -- verified by actual simulation, not by reading the code
and assuming it works.

**Doesn't prove**: FPGA synthesis or real hardware timing (this repo
has only been simulated with Icarus Verilog, not synthesized or run on
a real Xilinx part or ModelSim -- neither was available in this
environment); cryptographic strength (each key is just the previous
12-bit LFSR state shifted by one bit, so consecutive keys are strongly
correlated -- fine for a teaching lab exercise, not resistant to a
knowledgeable attacker); or behavior on a framing error (an
out-of-spec stop bit is a known, undefended lockup path in
`uart_receiver_fsm`, consistent with the original report's own stated
scope -- "Does not include error correction or parity checking" -- not
fixed here since it's outside that stated scope).
