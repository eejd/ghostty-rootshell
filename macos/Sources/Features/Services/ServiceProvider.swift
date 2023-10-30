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
        guard let str = pasteboard.string(forType: .string) else {
            error.pointee = Self.errorNoString
            return
        }
        
        openTerminal(str, target: .tab)
    }
    
    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let str = pasteboard.string(forType: .string) else {
            error.pointee = Self.errorNoString
            return
        }
        
        openTerminal(str, target: .window)
    }
    
    private func openTerminal(_ path: String, target: OpenTarget) {
        guard let delegateRaw = NSApp.delegate else { return }
        guard let delegate = delegateRaw as? AppDelegate else { return }
        let terminalManager = delegate.terminalManager
        
        // We only open in directories.
        var isDirectory = ObjCBool(true)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { return }
        
        // Build our config
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
        
        switch (target) {
        case .window:
            terminalManager.newWindow(withBaseConfig: config)
            
        case .tab:
            terminalManager.newTab(withBaseConfig: config)
        }
    }
}
