import Cocoa

/// Manages a set of terminal windows.
class TerminalManager {
    struct Window {
        let controller: TerminalController
    }
    
    let ghostty: Ghostty.AppState
    
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
        let window = createWindow(withBaseConfig: base).window!
        parent.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(self)
    }
    
    /// Creates a window controller, adds it to our managed list, and returns it.
    func createWindow(withBaseConfig: Ghostty.SurfaceConfiguration?) -> TerminalController {
        // Initialize our controller to load the window
        let c = TerminalController(ghostty)
        
        // Keep track of every window we manage
        windows.append(Window(controller: c))
        
        return c
    }
}
