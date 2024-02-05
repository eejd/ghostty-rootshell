#!/usr/bin/env bash

# TODO: This script is temporary, remove it from the repo


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
