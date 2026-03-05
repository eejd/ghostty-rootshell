import AppKit

/// Application-level Cocoa scripting hooks for the Ghostty AppleScript dictionary.
///
/// Cocoa scripting looks for specifically named Objective-C selectors derived
/// from the `sdef` file. This extension implements those required entry points
/// on `NSApplication`, which is the object behind the `application` class in
/// `Ghostty.sdef`.
@MainActor
extension NSApplication {
    /// Backing collection for `application.terminals`.
    ///
    /// Required selector name: `terminals`.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        allSurfaceViews.map(ScriptTerminal.init)
    }

    /// Enables AppleScript unique-ID lookup for terminal references.
    ///
    /// Required selector name pattern for element `terminals`:
    /// `valueInTerminalsWithUniqueID:`.
    ///
    /// This is what lets scripts do stable references like
    /// `terminal id "..."` even as windows/tabs change.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        allSurfaceViews
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// Handler for the `perform action` AppleScript command.
    ///
    /// Required selector name from the command in `sdef`:
    /// `handlePerformActionScriptCommand:`.
    ///
    /// Cocoa scripting parses script syntax and provides:
    /// - `directParameter`: the command string (`perform action "..."`).
    /// - `evaluatedArguments["on"]`: the target terminal (`... on terminal ...`).
    ///
    /// We return a Bool to match the command's declared result type.
    @objc(handlePerformActionScriptCommand:)
    func handlePerformActionScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let action = command.directParameter as? String else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing action string."
            return nil
        }

        guard let terminal = command.evaluatedArguments?["on"] as? ScriptTerminal else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing terminal target."
            return nil
        }

        return terminal.perform(action: action)
    }

    /// Discovers all currently alive terminal surfaces across normal and quick
    /// terminal windows. This powers both terminal enumeration and ID lookup.
    private var allSurfaceViews: [Ghostty.SurfaceView] {
        NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .flatMap { $0.surfaceTree.root?.leaves() ?? [] }
    }
}
