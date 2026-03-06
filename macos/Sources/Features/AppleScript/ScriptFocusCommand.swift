import AppKit

/// Handler for the `focus` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptFocusCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptFocusCommand)
final class ScriptFocusCommand: NSScriptCommand {
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

        controller.focusSurface(surfaceView)
        return nil
    }
}

/// Handler for the `activate window` AppleScript command defined in `Ghostty.sdef`.
@MainActor
@objc(GhosttyScriptActivateWindowCommand)
final class ScriptActivateWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let window = evaluatedArguments?["window"] as? ScriptWindow else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing window target."
            return nil
        }

        guard let targetWindow = window.preferredParentWindow else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Window is no longer available."
            return nil
        }

        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }
}

/// Handler for the `select tab` AppleScript command defined in `Ghostty.sdef`.
@MainActor
@objc(GhosttyScriptSelectTabCommand)
final class ScriptSelectTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let tab = evaluatedArguments?["tab"] as? ScriptTab else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing tab target."
            return nil
        }

        guard let targetWindow = tab.parentWindow else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Tab is no longer available."
            return nil
        }

        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }
}
