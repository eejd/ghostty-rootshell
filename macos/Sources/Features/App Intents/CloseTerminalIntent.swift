import AppKit
import AppIntents
import GhosttyKit

struct CloseTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Close Terminal"
    static var description = IntentDescription("Close an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal to close.",
    )
    var terminal: TerminalEntity

    @Parameter(
        title: "Command",
        description: "Command to execute instead of the default shell.",
        default: true
    )
    var confirm: Bool

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let surfaceView = terminal.surfaceView else {
            throw GhosttyIntentError.surfaceNotFound
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            return .result()
        }

        controller.closeSurface(surfaceView, withConfirmation: confirm)
        return .result()
    }
}
