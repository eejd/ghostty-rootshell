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
## AppleScript

- The AppleScript scripting definition is in `Ghostty.sdef`.
- Test AppleScript support:
  (1) Build with `build.nu`
  (2) Launch and activate the app via osascript using the absolute path
      to the built app bundle:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to activate'`
  (3) Wait a few seconds for the app to fully launch and open a terminal.
  (4) Run test scripts with `osascript`, always targeting the app by
      its absolute path (not by name) to avoid calling the wrong
      application.
  (5) When done, quit via:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to quit'`
