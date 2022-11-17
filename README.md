<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://user-images.githubusercontent.com/1299/199110421-9ff5fc30-a244-441e-9882-26070662adf9.png" alt="Logo" width="100">
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

**Project Status:** Alpha. It is a minimal terminal emulator that can be used
for day-to-day work. It is missing many nice to have features but as a minimal
terminal emulator it is ready to go. I've been using it full time since
April 2022.

## Roadmap and Status

The high-level ambitious plan for the project, in order:

| # | Step | Status |
|:---:|------|:------:|
| 1 | [Standards-compliant terminal emulation](docs/sequences.md)     | ⚠️ |
| 2 | Competitive rendering performance (not the fastest, but fast enough) | ✅ |
| 3 | Basic customizability -- fonts, bg colors, etc. | ✅ |
| 4 | Richer windowing features -- multi-window, tabbing, panes | ⚠️  |
| 5 | Native Platform Experiences (i.e. Mac Preference Panel) | ❌ |
| 6 | Windows Terminals (including PowerShell, Cmd, WSL) | ❌ |
| N | Fancy features (to be expanded upon later) | ❌ |

### Standards-Compliant Terminal Emulation

I am able to use this terminal as a daily driver. I think that's good enough
for a yellow status. There are a LOT of missing features for full standards
compliance but the set that are regularly in use are working pretty well.

### Competitive Rendering Performance

I want to benchmark this better, but we can maintain roughly 100fps under
heavy load and 120fps generally. We have a multi-renderer architecture that
uses OpenGL on Linux and Metal on macOS. As far as I'm aware, we're the only
terminal emulator other than iTerm that uses Metal directly. And we're the
only terminal emulator that has a Metal renderer that supports ligatures.

### Richer Windowing Features

We support multi-window and tabbing on Mac. We will support panes/splits
in the future and we'll continue to improve multi-window features.

### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but is meant to feel native
on each platform it runs on. On macOS, this means having a preferences window
that is a native Mac window (versus only file-based configuratin). On
Linux this means having a GTK option that has richer windowing features. Etc.

Right now, we're focusing on the macOS experience first. We are using Cocoa
with Metal and rendering text with CoreText. We will be working to improve
the windowing experience here.

## Developing Ghostty

Ghostty is built using both the [Zig](https://ziglang.org/) programming
language as well as the Zig build system. At a minimum, Zig and Git must be installed.
For [Nix](https://nixos.org/) users, a `shell.nix` is available which includes
all the necessary dependencies pinned to exact versions.

**Note: Zig nightly is required.** Ghostty is built against the nightly
releases of Zig. You can find binary releases of nightly builds
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

When running the app, logs are available via macOS unified logging such
as `Console.app`. The easiest way I've found is to just use the CLI:

```sh
$ sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
...
```
