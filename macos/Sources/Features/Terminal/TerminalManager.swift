import Cocoa
import SwiftUI
import GhosttyKit
import Combine

/// Manages a set of terminal windows. This is effectively an array of TerminalControllers.
/// This abstraction helps manage tabs and multi-window scenarios.
class TerminalManager {
    struct Window {
        let controller: TerminalController
        let closePublisher: AnyCancellable
    }
    
    let ghostty: Ghostty.AppState
    
    /// The currently focused surface of the main window.
    var focusedSurface: Ghostty.SurfaceView? { mainWindow?.controller.focusedSurface }
    
    /// The set of windows we currently have.
    private var windows: [Window] = []
    
    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)
    
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
        let center = NotificationCenter.default
        center.removeObserver(self)
    }
    
    // MARK: - Window Management
    
    /// Create a new terminal window.
    func newWindow(withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        let c = createWindow(withBaseConfig: base)
        if let window = c.window {
            Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
        }
        
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
        relabelTabs(parent)
        window.makeKeyAndOrderFront(self)
    }
    
    /// Creates a window controller, adds it to our managed list, and returns it.
    private func createWindow(withBaseConfig base: Ghostty.SurfaceConfiguration?) -> TerminalController {
        // Initialize our controller to load the window
        let c = TerminalController(ghostty, withBaseConfig: base)
        
        // Create a listener for when the window is closed so we can remove it.
        let pubClose = NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification,
            object: c.window!
        ).sink { notification in
            guard let window = notification.object as? NSWindow else { return }
            guard let c = window.windowController as? TerminalController else { return }
            self.removeWindow(c)
        }
        
        // Keep track of every window we manage
        windows.append(Window(
            controller: c,
            closePublisher: pubClose
        ))
        
        return c
    }
    
    private func removeWindow(_ controller: TerminalController) {
        // Remove it from our managed set
        guard let idx = self.windows.firstIndex(where: { $0.controller == controller }) else { return }
        let w = self.windows[idx]
        self.windows.remove(at: idx)
        
        // Ensure any publishers we have are cancelled
        w.closePublisher.cancel()
        
        // Removing the window can change tabs, so we need to relabel all tabs.
        // At this point, the window is already removed from the tab bar so
        // I don't know a way to only relabel the active tab bar, so just relabel
        // all of them.
        relabelAllTabs()
        
        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != controller.window {
                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: NSZeroPoint)
                return
            }
            
            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }
    
    /// Relabels all the tabs with the proper keyboard shortcut.
    func relabelAllTabs() {
        for w in windows {
            if let window = w.controller.window {
                relabelTabs(window)
            }
        }
    }
    
    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes and when a window is closed.
    private func relabelTabs(_ window: NSWindow) {
        guard let windows = window.tabbedWindows else { return }
        guard let cfg = ghostty.config else { return }
        for (index, window) in windows.enumerated().prefix(9) {
            let action = "goto_tab:\(index + 1)"
            let trigger = ghostty_config_trigger(cfg, action, UInt(action.count))
            guard let equiv = Ghostty.keyEquivalentLabel(key: trigger.key, mods: trigger.mods) else {
                continue
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.labelFont(ofSize: 0),
                .foregroundColor: window.isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let attributedString = NSAttributedString(string: " \(equiv) ", attributes: attributes)
            let text = NSTextField(labelWithAttributedString: attributedString)
            window.tab.accessoryView = text
        }
    }
    
    // MARK: - Notifications
    
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
