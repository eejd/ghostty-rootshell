# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ghostty is a fast, native, feature-rich terminal emulator written primarily in Zig with native platform UIs (SwiftUI for macOS, GTK for Linux). It aims to be standards-compliant, performant, and provide a native experience on each platform while sharing a common Zig core.

## Build Commands

### Standard Build
- **Build (macOS, typical):** `zig build -Doptimize=ReleaseFast -Demit-xcframework`
- **Build (general):** `zig build -Doptimize=ReleaseFast`
- **Run:** `zig build run -Doptimize=ReleaseFast` (accepts additional args after `--`)
- **Debug build:** `zig build` (omit `-Doptimize` for debug mode, use when troubleshooting)
- **Clean:** `make clean` or manually delete `zig-out`, `.zig-cache`, `macos/build`

**Note:** ReleaseFast is the preferred optimization mode since terminal emulators are performance-sensitive. For macOS development, typically build the xcframework (`-Demit-xcframework`) which is consumed by the Xcode project.

### Testing
- **All tests:** `zig build test`
- **Filtered tests:** `zig build test -Dtest-filter=<filter>`
- **libghostty-vt tests:** `zig build test-lib-vt`
- **Valgrind tests (Linux):** `zig build run-valgrind` or `zig build test-valgrind`

### libghostty-vt
- **Build:** `zig build lib-vt`
- **Build Wasm:** `zig build lib-vt -Dtarget=wasm32-freestanding`
- When working on libghostty-vt, avoid building the full app unnecessarily
- For C-only changes, build the examples instead of running Zig tests

### Platform-Specific
- **macOS xcframework:** `zig build -Doptimize=ReleaseFast -Demit-xcframework` (default for macOS development)
- **macOS xcframework (universal):** `zig build -Doptimize=ReleaseFast -Demit-xcframework -Dxcframework-target=universal`
- **macOS app:** Use `zig build` only; do NOT use `xcodebuild` directly
- **Build docs:** `zig build -Demit-docs`
- **Update translations:** `zig build update-translations`
- **Distribution tarball:** `zig build dist` or `zig build distcheck`

### Linting
- **Zig code:** `zig fmt .`
- **Other files (docs, resources):** `prettier --write .`
- **Nix files:** `alejandra .`

## Requirements

- **Zig version:** See `build.zig.zon` for `minimum_zig_version` (currently 0.15.2)
- **macOS development:** Requires Xcode 26 and macOS 26 SDK (can run on macOS 15)
- **Linux development:** Requires `blueprint-compiler` (≥0.16.0) when building from git

## High-Level Architecture

### Multi-Platform Design

Ghostty uses a layered architecture with a shared core and platform-specific runtimes:

1. **Shared Zig Core** (`src/`): Terminal emulation, parsing, rendering logic, configuration
2. **Platform Runtimes** (`app_runtime`):
   - **macOS:** Swift/SwiftUI app consuming `libghostty` C API (`macos/Sources/`)
   - **GTK:** Native GTK integration (`src/apprt/gtk/`)
   - **none:** libghostty library mode

The macOS app demonstrates the embedding use case: it's a native Swift app with `main()` in Swift that links to and uses the C API (`include/ghostty.h`).

### Core Components

- **Terminal** (`src/terminal/Terminal.zig`): The primary terminal emulation structure containing the character grid, scrollback buffer, and terminal state (screens, modes, colors, etc.)
- **Surface** (`src/Surface.zig`): Represents a single terminal surface with rendering and input handling
- **App** (`src/App.zig`): Top-level application coordinator
- **Config** (`src/config/`): Configuration system with file loading, parsing, and conditional config
- **Renderer** (`src/renderer/`): Multi-backend rendering (Metal for macOS, OpenGL for Linux)
- **Font** (`src/font/`): Font discovery and rasterization (CoreText on macOS, FreeType on Linux)
- **Input** (`src/input/`): Input handling and key encoding
- **Terminal I/O** (`src/termio/`): PTY and process management with platform-specific backends

### libghostty and libghostty-vt

- **libghostty**: C-compatible embedding API for the full terminal emulator (used by macOS app)
  - Header: `include/ghostty.h`
  - C API implementation: `src/main_c.zig`
- **libghostty-vt**: Standalone library for VT parsing and terminal state (subset, more portable)
  - Entrypoint: `src/lib_vt.zig`
  - Supports Zig, C, WebAssembly

### Build System

- **Primary build:** `build.zig` using Zig build system
- **Build modules:** `src/build/` contains build logic components
  - `Config.zig`: Build configuration with feature flags and targets
  - `GhosttyExe.zig`, `GhosttyLib.zig`, `GhosttyLibVt.zig`: Artifact builders
  - `GhosttyXcodebuild.zig`: macOS app build integration
  - `GhosttyXCFramework.zig`: XCFramework generation for macOS/iOS

## Development Workflow

### Making Changes

1. **Read before modifying**: Always read existing files before suggesting changes
2. **Build mode**: Always use `-Doptimize=ReleaseFast` for builds; only use debug mode (plain `zig build`) when diagnosing specific issues
3. **macOS workflow**: Build the xcframework with `-Demit-xcframework` when working on macOS
4. **Incremental testing**: Use `-Dtest-filter=<name>` to run specific tests during development
5. **Environment variable**: Set `GHOSTTY_RESOURCES_DIR` when testing to point to `zig-out/share/ghostty`

### Common Pitfalls

- **Input stack changes**: If modifying input handling, manually verify IME on Linux (see HACKING.md Input Stack Testing section)
- **macOS SDK**: Ensure Xcode 26 is selected with `xcode-select`
- **Config changes**: Update help strings and docs when adding config options

### Code Organization

- Terminal emulation control sequences: `src/terminal/ansi.zig`, `csi.zig`, `kitty.zig`
- Platform abstraction: `src/os/` (pty, IPC, file operations)
- Character grid: `src/terminal/Screen.zig`, `page.zig`, `Cell` types
- Data structures: `src/datastruct/` (common utilities)

## Contributing Guidelines

- All PRs must implement an existing issue (see CONTRIBUTING.md)
- AI assistance must be disclosed in PR
- Follow existing code style (run `zig fmt .`)
- Avoid over-engineering; only implement what's requested
- Don't add backwards-compatibility shims for removed code
- Security: Watch for command injection, XSS, SQL injection, etc.

## Testing

- **Unit tests**: Inline tests in Zig source files
- **Acceptance tests**: `test/` directory with screenshot-based visual verification
- **Continuous integration**: `.github/workflows/test.yml` runs full test suite
- Single test case: `cd test && ./run-host.sh --case /src/cases/<test>.sh`
