# AFL++ Fuzzer for Libghostty

This directory contains an [AFL++](https://aflplus.plus/) fuzzing harness for
libghostty-vt (Zig module). At the time of writing this README, it only
fuzzes the VT parser, but it can be extended to cover other components of
libghostty as well.

## Prerequisites

Install AFL++ so that `afl-cc` and `afl-fuzz` are on your `PATH`.

- **macOS (Homebrew):** `brew install aflplusplus`
- **Linux:** build from source or use your distro's package (e.g.
  `apt install afl++` on Debian/Ubuntu).

## Building

From this directory (`test/fuzz-libghostty`):

```sh
zig build
```

This compiles a Zig static library (with the fuzz harness in `src/lib.zig`),
emits LLVM bitcode, then links it with `src/main.c` using `afl-cc` to produce
the instrumented binary at `zig-out/bin/ghostty-fuzz`.

## Running the Fuzzer

The build system has a convenience step that invokes `afl-fuzz` with the
correct arguments:

```sh
zig build run
```

This is equivalent to:

```sh
afl-fuzz -i corpus/initial -o afl-out -- zig-out/bin/ghostty-fuzz @@
```

You may want to run `afl-fuzz` directly with different options
for your own experimentation.

The fuzzer runs indefinitely. Let it run for as long as you like; meaningful
coverage is usually reached within a few hours, but longer runs can find
deeper bugs. Press `ctrl+c` to stop the fuzzer when you're done.

## Finding Crashes and Hangs

After (or during) a run, results are written to `afl-out/default/`:

```

afl-out/default/
├── crashes/ # Inputs that triggered crashes
├── hangs/ # Inputs that triggered hangs/timeouts
└── queue/ # All interesting inputs (the evolved corpus)

```

Each file in `crashes/` or `hangs/` is a raw byte file that triggered the
issue. The filename encodes metadata about how it was found (e.g.
`id:000000,sig:06,...`).

## Reproducing a Crash

Replay any crashing input by passing it directly to the harness:

```sh
# Via command-line argument
zig-out/bin/ghostty-fuzz afl-out/default/crashes/<filename>
```
