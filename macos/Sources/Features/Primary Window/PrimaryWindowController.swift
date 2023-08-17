import Cocoa

class PrimaryWindowController: NSWindowController {
    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    static var lastCascadePoint = NSPoint(x: 0, y: 0)
    
    // This is used to programmatically control tabs.
    weak var windowManager: PrimaryWindowManager?
    
    // This is required for the "+" button to show up in the tab bar to add a
    // new tab.
    override func newWindowForTab(_ sender: Any?) {
        guard let window = self.window as? PrimaryWindow else { preconditionFailure("Expected window to be loaded") }
        guard let manager = self.windowManager else { return }
        manager.newTabForWindow(window: window)
    }
}
