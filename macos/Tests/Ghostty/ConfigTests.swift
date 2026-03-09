import Testing
@testable import Ghostty

/// Create a temporary config file and delete it when this is deallocated
class TemporaryConfig: Ghostty.Config {
    let temporaryFile: URL

    init(_ configText: String, finalize: Bool = false) throws {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
        try configText.write(to: temporaryFile, atomically: true, encoding: .utf8)
        self.temporaryFile = temporaryFile
        super.init(config: Self.loadConfig(at: temporaryFile.path(), finalize: finalize))
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryFile)
    }
}
