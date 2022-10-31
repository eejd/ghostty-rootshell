<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://user-images.githubusercontent.com/1299/161641319-7778cc19-a69a-4041-8cdf-8aad9ce1ffe3.png" alt="Logo" width="70">
  <br>ghostty
</h1>
  <p align="center">
    GPU-accelerated terminal emulator pushing modern features.
    <br />
    </p>
</p>

## About

ghostty is a cross-platform, GPU-accelerated terminal emulator that aims to
push the boundaries of what is possible with a terminal emulator by exposing
modern, opt-in features that enable CLI tool developers to build more feature
rich, interactive applications.

There are a number of excellent terminal emulator options that exist
today. The unique goal of ghostty is to have a platform for experimenting
with modern, optional, non-standards-compliant features to enhance the
capabilities of CLI applications. We aim to be the best in this category,
and competitive in the rest.

While aiming for this ambitious goal, ghostty is a fully standards compliant
terminal emulator that aims to remain compatible with all existing shells
and software. You can use this as a drop-in replacement for your existing
terminal emulator.

**Project Status:** Pre-Alpha. It now supports enough to be used day to day
for my use case, but is still missing a lot of functionality.

## Roadmap and Status

The high-level ambitious plan for the project, in order:

| # | Step | Status |
|:---:|------|:------:|
| 1 | [Standards-compliant terminal emulation](docs/sequences.md)     | ⚠️ |
| 2 | Competitive rendering performance (not the fastest, but fast enough) | ✅ |
| 3 | Basic customizability -- fonts, bg colors, etc. | ❌ |
| 4 | Richer windowing features -- multi-window, tabbing, panes | ❌ |
| 5 | Optimal rendering performance | ❌ |
| N | Fancy features (to be expanded upon later) | ❌ |

### Standards-Compliant Terminal Emulation

I am able to use this terminal as a daily driver. I think that's good enough
for a yellow status. There are a LOT of missing features for full standards
compliance but the set that are regularly in use are working pretty well.

### Competitive Rendering Performance

I want to automate the testing of this, but for now I've manually verified
we can maintain 120fps `cat`-ing a 6MB file. In terms of raw draw speed,
`cat`-ing a 6MB file is consistently faster on Linux using ghostty than
any other terminal emulator currently.

On macOS, `cat`-ing the large file is acceptable performance but not optimal.
I don't know why and need to look into it.

## Developing Ghostty

Ghostty is built using both the [Zig](https://ziglang.org/) programming
language as well as the Zig build system. At a minimum, Zig must be installed.
For [Nix](https://nixos.org/) users, a `shell.nix` is available which includes
all the necessary dependencies pinned to exact versions.

**Note: Zig nightly is required.** Ghostty is built against the nightly
releases of Zig. The latest released version (0.9.1 at the time of this
edit) will NOT work. You can find binary releases of nightly builds
on the [Zig downloads page](https://ziglang.org/download/).

With Zig installed, a binary can be built using `zig build`:

```shell-session
$ zig build
...

$ zig-out/bin/ghostty
```

This will build a binary for the currently running system (if supported).
You can cross compile by setting `-Dtarget=<target-triple>`. For example,
`zig build -Dtarget=aarch64-macos` will build for Apple Silicon macOS. Note
that not all targets supported by Zig are supported.

Other useful commands:

  * `zig build test` for running unit tests.
  * `zig build run -Dconformance=<name>` run a conformance test case from
    the `conformance` directory. The `name` is the name of the file. This runs
    in the current running terminal emulator so if you want to check the
    behavior of this project, you must run this command in ghostty.

### Compiling a Release Build

The normal build will be a _debug build_ which includes a number of
safety features as well as debugging features that dramatically slow down
normal operation of the terminal (by as much as 100x). If you are building
a terminal for day to day usage, build a release version:

```shell-session
$ zig build -Drelease-fast
...
```

You can verify you have a release version by checking the filesize of the
built binary (`zig-out/bin/ghostty`). The release version should be less
than 5 MB on all platforms. The debug version is around 70MB.

### Mac `.app`

When targeting macOS, a macOS application bundle will be created at
`zig-out/Ghostty.app`. This can be copied as-is and used like a normal app.
This app will be not be signed or notarized.
