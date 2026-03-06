# macOS Ghostty Application

- Use `swiftlint` for formatting and linting Swift code.
- If code outside of this directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying Ghostty library.
- Use `build.nu` to build the macOS app, do not use `zig build`
  (except to build the underlying library as mentioned above).
  - Build: `build.nu [--scheme Ghostty] [--configuration Debug] [--action build]`
  - Output: `build/<configuration>/Ghostty.app` (e.g. `build/Debug/Ghostty.app`)
- Run unit tests directly with `build.nu --action test`
