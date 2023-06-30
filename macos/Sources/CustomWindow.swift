import Cocoa
import SwiftUI
import GhosttyKit

// FocusedSurfaceWrapper is here so that we can pass a reference down
// the view hierarchy and keep track of which surface is focused.
class FocusedSurfaceWrapper {
    var surface: ghostty_surface_t?
}

// CustomWindow exists purely so we can override canBecomeKey and canBecomeMain.
// We need that for the non-native fullscreen.
// If we don't use `CustomWindow` we'll get warning messages in the output to say that
// `makeKeyWindow` was called and returned NO.
class CustomWindow: NSWindow {
    var focusedSurfaceWrapper: FocusedSurfaceWrapper = FocusedSurfaceWrapper()

    static func create(ghostty: Ghostty.AppState, appDelegate: AppDelegate) -> CustomWindow {
        let window = CustomWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        window.contentView = NSHostingView(rootView: ContentView(
            ghostty: ghostty,
            appDelegate: appDelegate,
            focusedSurfaceWrapper: window.focusedSurfaceWrapper))
        window.windowController?.shouldCascadeWindows = true
        return window
    }
    
    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }
}
