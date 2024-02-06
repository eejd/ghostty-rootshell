#!/usr/bin/env bash
#
# This is a trivial helper script to help run the stream benchmark.
# You probably want to tweak this script depending on what you're
# trying to measure.

DATA="ascii"
SIZE="25M"

# Uncomment to test with an active terminal state.
#ARGS=" --terminal"

hyperfine \
  --warmup 10 \
  -n memcpy \
  "./zig-out/bin/bench-stream --mode=gen-${DATA} | head -c ${SIZE} | ./zig-out/bin/bench-stream --mode=noop${ARGS}" \
  -n scalar \
  "./zig-out/bin/bench-stream --mode=gen-${DATA} | head -c ${SIZE} | ./zig-out/bin/bench-stream --mode=scalar${ARGS}" \
  -n simd \
  "./zig-out/bin/bench-stream --mode=gen-${DATA} | head -c ${SIZE} | ./zig-out/bin/bench-stream --mode=simd${ARGS}"
