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

/// Handler for the `close tab` AppleScript command defined in `Ghostty.sdef`.
@MainActor
@objc(GhosttyScriptCloseTabCommand)
final class ScriptCloseTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let tab = evaluatedArguments?["tab"] as? ScriptTab else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing tab target."
            return nil
        }

        guard let controller = tab.parentController else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Tab is no longer available."
            return nil
        }

        if let terminalController = controller as? TerminalController {
            terminalController.closeTabImmediately(registerRedo: false)
            return nil
        }

        guard let targetWindow = tab.parentWindow else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Tab window is no longer available."
            return nil
        }

        targetWindow.close()
        return nil
    }
}

/// Handler for the `close window` AppleScript command defined in `Ghostty.sdef`.
@MainActor
@objc(GhosttyScriptCloseWindowCommand)
final class ScriptCloseWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let window = evaluatedArguments?["window"] as? ScriptWindow else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing window target."
            return nil
        }

        if let terminalController = window.preferredController as? TerminalController {
            terminalController.closeWindowImmediately()
            return nil
        }

        guard let targetWindow = window.preferredParentWindow else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Window is no longer available."
            return nil
        }

        targetWindow.close()
        return nil
    }
}
