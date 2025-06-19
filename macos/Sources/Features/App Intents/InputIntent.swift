import AppKit
import AppIntents

/// App intent to input text in a terminal.
struct InputTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Input Text to Terminal"

    @Parameter(
        title: "Text",
        description: "The text to input to the terminal. The text will be inputted as if it was pasted.",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var text: String

    @Parameter(
        title: "Terminal",
        description: "The terminal to scope this action to."
    )
    var terminal: TerminalEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = [.background, .foreground]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        surface.sendText(text)
        return .result()
    }
}

/// App intent to trigger a keyboard event.
struct KeyEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Keyboard Event to Terminal"
    static var description = IntentDescription("Simulate a keyboard event. This will not handle text encoding; use the 'Input Text' action for that.")

    @Parameter(
        title: "Text",
        description: "The key to send to the terminal."
    )
    var key: KeyIntentKey

    @Parameter(
        title: "Terminal",
        description: "The terminal to scope this action to."
    )
    var terminal: TerminalEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = [.background, .foreground]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        surface.sendText(text)
        return .result()
    }
}

// MARK: TerminalDetail

enum KeyIntentKey: String {
    case title
    case workingDirectory
    case allContents
    case selectedText
    case visibleText
}

extension KeyIntentKey: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Detail")

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .title: .init(title: "Title"),
        .workingDirectory: .init(title: "Working Directory"),
        .allContents: .init(title: "Full Contents"),
        .selectedText: .init(title: "Selected Text"),
        .visibleText: .init(title: "Visible Text"),
    ]
}
