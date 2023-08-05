import Cocoa

class PrimaryWindowController: NSWindowController {
    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    static var lastCascadePoint = NSPoint(x: 0, y: 0)
    
    static func create(ghosttyApp: Ghostty.AppState, appDelegate: AppDelegate) -> PrimaryWindowController {
        let window = PrimaryWindow.create(ghostty: ghosttyApp, appDelegate: appDelegate)
        lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        return PrimaryWindowController(window: window)
    }
}
