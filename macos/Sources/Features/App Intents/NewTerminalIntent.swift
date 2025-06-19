import AppKit
import AppIntents

/// App intent that allows creating a new terminal window or tab.
///
/// This requires macOS 15 or greater because we use features of macOS 15 here.
@available(macOS 15.0, *)
struct NewTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "New Terminal"
    static var description = IntentDescription("Create a new terminal.")

    @Parameter(
        title: "Location",
        description: "The location that the terminal should be created.",
        default: .window
    )
    var location: NewTerminalLocation

    @Parameter(
        title: "Working Directory",
        description: "The working directory to open in the terminal.",
        supportedContentTypes: [.folder]
    )
    var workingDirectory: IntentFile?

    @Parameter(
        title: "Parent Terminal",
        description: "The terminal to inherit the base configuration from."
    )
    var parent: TerminalEntity?

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .foreground(.immediate)

    @available(macOS, obsoleted: 26.0, message: "Replaced by supportedModes")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            throw GhosttyIntentError.appUnavailable
        }

        var config = Ghostty.SurfaceConfiguration()

        // If we were given a working directory then open that directory
        if let url = workingDirectory?.fileURL {
            let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            config.workingDirectory = dir.path(percentEncoded: false)
        }

        // Determine if we have a parent and get it
        let parent: Ghostty.SurfaceView?
        if let parentParam = self.parent {
            guard let view = parentParam.surfaceView else {
                throw GhosttyIntentError.surfaceNotFound
            }

            parent = view
        } else if let preferred = TerminalController.preferredParent {
            parent = preferred.focusedSurface ?? preferred.surfaceTree.root?.leftmostLeaf()
        } else {
            parent = nil
        }

        switch location {
        case .window:
            _ = TerminalController.newWindow(
                appDelegate.ghostty,
                withBaseConfig: config,
                withParent: parent?.window)

        case .tab:
            _ = TerminalController.newTab(
                appDelegate.ghostty,
                from: parent?.window,
                withBaseConfig: config)
        }

        return .result()
    }
}

// MARK: NewTerminalLocation

enum NewTerminalLocation: String {
    case tab
    case window
}

extension NewTerminalLocation: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Location")

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .tab: .init(title: "Tab"),
        .window: .init(title: "Window"),
    ]
}
