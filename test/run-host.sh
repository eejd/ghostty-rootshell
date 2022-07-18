#!/usr/bin/env bash
#
# This runs a single test case from the host (not from Docker itself). The
# arguments are the same as run.sh but this wraps it in docker.

if [ ! -f "ghostty" ]; then
  cp ../zig-out/bin/ghostty .
fi

docker run \
  --init \
  --rm \
  -v $(pwd):/src \
  --entrypoint "xvfb-run" \
  $(docker build -q .) \
  /entrypoint.sh $@
