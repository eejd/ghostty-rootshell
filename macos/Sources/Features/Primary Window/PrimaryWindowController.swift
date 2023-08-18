import Cocoa

class PrimaryWindowController: NSWindowController {
    // This is used to programmatically control tabs.
    weak var windowManager: PrimaryWindowManager?
    
    // This is required for the "+" button to show up in the tab bar to add a
    // new tab.
    override func newWindowForTab(_ sender: Any?) {
        guard let window = self.window as? PrimaryWindow else { preconditionFailure("Expected window to be loaded") }
        guard let manager = self.windowManager else { return }
        manager.triggerNewTab(for: window)
    }
}
