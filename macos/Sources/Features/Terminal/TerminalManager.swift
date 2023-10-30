import Cocoa
import SwiftUI

/// Manages a set of terminal windows.
class TerminalManager {
    struct Window {
        let controller: TerminalController
    }
    
    let ghostty: Ghostty.AppState
    
    /// The currently focused surface of the main window.
    var focusedSurface: Ghostty.SurfaceView? { mainWindow?.controller.focusedSurface }
    
    /// The set of windows we currently have.
    private var windows: [Window] = []
    
    /// Returns the main window of the managed window stack. If there is no window
    /// then an arbitrary window will be chosen.
    private var mainWindow: Window? {
        for window in windows {
            if (window.controller.window?.isMainWindow ?? false) {
                return window
            }
        }
        
        // If we have no main window, just use the first window.
        return windows.first
    }
    
    init(_ ghostty: Ghostty.AppState) {
        self.ghostty = ghostty
        
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onNewTab),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onNewWindow),
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
    }
    
    deinit {
        let center = NotificationCenter.default;
        center.removeObserver(
            self,
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
        center.removeObserver(
            self,
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
    }
    
    /// Create a new terminal window.
    func newWindow(withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        let c = createWindow(withBaseConfig: base)
        c.showWindow(self)
    }
    
    /// Creates a new tab in the current main window. If there are no windows, a window
    /// is created.
    func newTab(withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        // If there is no main window, just create a new window
        guard let parent = mainWindow?.controller.window else {
            newWindow(withBaseConfig: base)
            return
        }
        
        // Create a new window and add it to the parent
        newTab(to: parent, withBaseConfig: base)
    }
    
    private func newTab(to parent: NSWindow, withBaseConfig base: Ghostty.SurfaceConfiguration?) {
        // Create a new window and add it to the parent
        let window = createWindow(withBaseConfig: base).window!
        parent.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(self)
    }
    
    /// Creates a window controller, adds it to our managed list, and returns it.
    private func createWindow(withBaseConfig: Ghostty.SurfaceConfiguration?) -> TerminalController {
        // Initialize our controller to load the window
        let c = TerminalController(ghostty)
        
        // Keep track of every window we manage
        windows.append(Window(controller: c))
        
        return c
    }
    
    @objc private func onNewWindow(notification: SwiftUI.Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        self.newWindow(withBaseConfig: config)
    }
    
    @objc private func onNewTab(notification: SwiftUI.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }
        
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        
        self.newTab(to: window, withBaseConfig: config)
    }
}
