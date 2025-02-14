#!/bin/sh

# NOTE THIS IS A TEMPORARY SCRIPT TO SUPPORT PACKAGE MAINTAINERS.
# Since #5439[1], we've been moving away from this and using an alternate
# nix-based approach to cache our dependencies. #5733 aims to make this more
# readily consumable by people who don't have Nix installed so that Nix
# is not a hard dependency.
#
# Further, a future Zig version will hopefully fix the issue where
# `zig build --fetch` doesn't fetch transitive dependencies[3]. When that
# is resolved, we won't need any special machinery for the general use case
# at all and packagers can just use `zig build --fetch`.
#
# [1]: https://github.com/ghostty-org/ghostty/pull/5439
# [2]: https://github.com/ghostty-org/ghostty/pull/5733
# [3]: https://github.com/ziglang/zig/issues/20976

if [ -z ${ZIG_GLOBAL_CACHE_DIR+x} ]
then
  echo "must set ZIG_GLOBAL_CACHE_DIR!"
  exit 1
fi

zig build --fetch
zig fetch git+https://github.com/zigimg/zigimg#3a667bdb3d7f0955a5a51c8468eac83210c1439e
zig fetch git+https://github.com/mitchellh/libxev#f6a672a78436d8efee1aa847a43a900ad773618b
