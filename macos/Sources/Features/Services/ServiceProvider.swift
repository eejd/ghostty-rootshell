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
        guard let windowManager = delegate.windowManager else { return }
        
        // We only open in directories.
        var isDirectory = ObjCBool(true)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { return }
        
        // Build our config
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
            
        // If we don't have a window open through the window manager, we launch
        // a new window even if they requested a tab.
        guard let mainWindow = windowManager.mainWindow else {
            windowManager.addNewWindow(withBaseConfig: config)
            return
        }
        
        switch (target) {
        case .window:
            windowManager.addNewWindow(withBaseConfig: config)
            
        case .tab:
            windowManager.addNewTab(to: mainWindow, withBaseConfig: config)
        }
    }
}
