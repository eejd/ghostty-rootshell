import AppKit

/// Handler for the `split` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptSplitCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptSplitCommand)
final class ScriptSplitCommand: NSScriptCommand {
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

        guard let directionCode = evaluatedArguments?["direction"] as? UInt32,
              let direction = ScriptSplitDirection(code: directionCode) else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing or unknown split direction."
            return nil
        }

        let baseConfig: Ghostty.SurfaceConfiguration
        do {
            if let scriptRecord = evaluatedArguments?["configuration"] as? NSDictionary {
                baseConfig = try Ghostty.SurfaceConfiguration(scriptRecord: scriptRecord)
            } else {
                baseConfig = Ghostty.SurfaceConfiguration()
            }
        } catch {
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = error.localizedDescription
            return nil
        }

        // Find the window controller that owns this surface.
        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal is not in a splittable window."
            return nil
        }

        guard let newView = controller.newSplit(
            at: surfaceView,
            direction: direction.splitDirection,
            baseConfig: baseConfig
        ) else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Failed to create split."
            return nil
        }

        return ScriptTerminal(surfaceView: newView)
    }
}

/// Four-character codes matching the `split direction` enumeration in `Ghostty.sdef`.
private enum ScriptSplitDirection {
    case right
    case left
    case down
    case up

    init?(code: UInt32) {
        switch code {
        case "GSrt".fourCharCode: self = .right
        case "GSlf".fourCharCode: self = .left
        case "GSdn".fourCharCode: self = .down
        case "GSup".fourCharCode: self = .up
        default: return nil
        }
    }

    var splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection {
        switch self {
        case .right: .right
        case .left: .left
        case .down: .down
        case .up: .up
        }
    }
}
