import AppKit

/// Handler for the `close` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptCloseCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptCloseCommand)
final class ScriptCloseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return nil
        }

        guard let surfaceView = terminal.surfaceView else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal is not in a window."
            return nil
        }

        controller.closeSurface(surfaceView, withConfirmation: false)
        return nil
    }
}
