import Cocoa

class WindowController: NSWindowController {
    static var lastCascadePoint = NSPoint(x: 0, y: 0)
    
    static func create(ghosttyApp: Ghostty.AppState, appDelegate: AppDelegate) -> WindowController {
        let window = CustomWindow.create(ghostty: ghosttyApp, appDelegate: appDelegate)
        lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        return WindowController(window: window)
    }
}
