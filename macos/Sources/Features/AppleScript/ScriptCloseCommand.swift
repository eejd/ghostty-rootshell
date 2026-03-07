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
        guard NSApp.validateScript(command: self) else { return nil }

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

/// Handler for the container-level `close tab` AppleScript command defined in
/// `Ghostty.sdef`.
@MainActor
@objc(GhosttyScriptCloseTabCommand)
final class ScriptCloseTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let tab = evaluatedArguments?["tab"] as? ScriptTab else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing tab target."
            return nil
        }

        guard let tabController = tab.parentController else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Tab is no longer available."
            return nil
        }

        if let managedTerminalController = tabController as? TerminalController {
            managedTerminalController.closeTabImmediately(registerRedo: false)
            return nil
        }

        guard let tabContainerWindow = tab.parentWindow else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Tab container window is no longer available."
            return nil
        }

        tabContainerWindow.close()
        return nil
    }
}

/// Handler for the container-level `close window` AppleScript command defined in
/// `Ghostty.sdef`.
@MainActor
@objc(GhosttyScriptCloseWindowCommand)
final class ScriptCloseWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let window = evaluatedArguments?["window"] as? ScriptWindow else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing window target."
            return nil
        }

        if let managedTerminalController = window.preferredController as? TerminalController {
            managedTerminalController.closeWindowImmediately()
            return nil
        }

        guard let windowContainer = window.preferredParentWindow else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Window is no longer available."
            return nil
        }

        windowContainer.close()
        return nil
    }
}
