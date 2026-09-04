#!/usr/bin/env bash
# Compiles and runs the testbench(es) with Icarus Verilog.
# Requires: iverilog + vvp on PATH (https://github.com/steveicarus/iverilog)
#
# Usage:
#   sim/run.sh             # system-level test: UART -> encrypt -> decrypt -> UART
#   sim/run.sh --trace     # same, plus a per-cycle signal trace
#   sim/run.sh --lfsr-test # standalone LFSR period / lock-up test (tb/lfsr_period_test.v)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--lfsr-test" ]]; then
  iverilog -g2012 -o sim/lfsr_test.vvp \
    rtl/crypto_encoder_block.v \
    tb/lfsr_period_test.v
  vvp sim/lfsr_test.vvp
  exit 0
fi

iverilog -g2012 -o sim/tb.vvp \
  rtl/baud_tick_gen.v \
  rtl/crypto_encoder_block.v \
  rtl/crypto_decoder_block.v \
  rtl/uart_receiver_fsm.v \
  rtl/uart_transmitter_fsm.v \
  rtl/system_control_fsm.v \
  rtl/top_system_integration.v \
  tb/top_system_testbench.v

if [[ "${1:-}" == "--trace" ]]; then
  vvp sim/tb.vvp +DEBUG_TRACE
else
  vvp sim/tb.vvp
fi
