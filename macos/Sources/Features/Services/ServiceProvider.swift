import Foundation
import AppKit

class ServiceProvider: NSObject {
    static private let errorNoString = NSString(string: "Could not load any text from the clipboard.")

    /// The target for an open operation
    enum OpenTarget {
        case tab
        case window
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminalFromPasteboard(pasteboard: pasteboard, target: .tab, error: error)
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminalFromPasteboard(pasteboard: pasteboard, target: .window, error: error)
    }

    @inline(__always)
    private func openTerminalFromPasteboard(
        pasteboard: NSPasteboard,
        target: OpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let objs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [NSURL] else {
            error.pointee = Self.errorNoString
            return
        }
        let filePaths = objs.map { $0.path }.compactMap { $0 }

        openTerminal(filePaths, target: target)
    }

    private func openTerminal(_ paths: [String], target: OpenTarget) {
        guard let delegateRaw = NSApp.delegate else { return }
        guard let delegate = delegateRaw as? AppDelegate else { return }
        let terminalManager = delegate.terminalManager

        for path in paths {
            // Check if the path exists and determine if it's a directory
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }

            let targetDirectoryPath: String

            if isDirectory.boolValue {
                // Path is already a directory, use it directly
                targetDirectoryPath = path
            } else {
                // Path is a file, get its parent directory
                let parentDirectoryPath = (path as NSString).deletingLastPathComponent
                var isParentPathDirectory = ObjCBool(true)
                guard FileManager.default.fileExists(atPath: parentDirectoryPath, isDirectory: &isParentPathDirectory),
                    isParentPathDirectory.boolValue else {
                    continue
                }
                targetDirectoryPath = parentDirectoryPath
            }

            // Build our config
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = targetDirectoryPath

            switch (target) {
            case .window:
                terminalManager.newWindow(withBaseConfig: config)

            case .tab:
                terminalManager.newTab(withBaseConfig: config)
            }
        }

    }
}
