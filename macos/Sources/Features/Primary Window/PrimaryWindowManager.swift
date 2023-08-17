import Cocoa
import Combine
import SwiftUI

// PrimaryWindowManager manages the windows and tabs in the primary window
// of the application. It keeps references to windows and cleans them up when
// they're cloned.
//
// If we ever have multiple tabbed window types we can make this generic but
// right now only our primary window is ever duplicated or tabbed so we're not
// doing that.
//
// It is based on the patterns presented in this blog post:
// https://christiantietze.de/posts/2019/07/nswindow-tabbing-multiple-nswindowcontroller/
class PrimaryWindowManager {
    struct ManagedWindow {
        let windowController: NSWindowController
        let window: NSWindow
        let closePublisher: AnyCancellable
    }
    
    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    static var lastCascadePoint = NSPoint(x: 0, y: 0)
    
    /// Returns the main window of the managed window stack.
    /// Falls back the first element if no window is main. Note that this would
    /// likely be an internal inconsistency we gracefully handle here.
    var mainWindow: NSWindow? {
        let mainManagedWindow = managedWindows
            .first { $0.window.isMainWindow }

        // In case we run into the inconsistency, let it crash in debug mode so we
        // can fix our window management setup to prevent this from happening.
        assert(mainManagedWindow != nil || managedWindows.isEmpty)

        return (mainManagedWindow ?? managedWindows.first)
            .map { $0.window }
    }

    private var ghostty: Ghostty.AppState
    private var managedWindows: [ManagedWindow] = []
    
    init(ghostty: Ghostty.AppState) {
        self.ghostty = ghostty
        
        // Register self as observer for the NewTab notification that
        // is triggered via callback from Zig code.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onNewTab),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
    }
    
    deinit {
        // Clean up the observer.
        NotificationCenter.default.removeObserver(
            self,
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
    }
    
    /// Add the initial window for the application. This should only be called once from the AppDelegate.
    func addInitialWindow() {
        guard let controller = createWindowController() else { return }
        controller.showWindow(self)
        let result = addManagedWindow(windowController: controller)
        if result == nil {
            preconditionFailure("Failed to create initial window")
        }
    }
    
    func addNewWindow() {
        guard let controller = createWindowController() else { return }
        guard let newWindow = addManagedWindow(windowController: controller)?.window else { return }
        newWindow.makeKeyAndOrderFront(nil)
    }
    
    func newTabForWindow(window: PrimaryWindow) {
        guard let surface = window.focusedSurfaceWrapper.surface else { return }
        ghostty.newTab(surface: surface)
    }
    
    func newTab() {
        if mainWindow != nil {
            guard let window = mainWindow as? PrimaryWindow else { return }
            self.newTabForWindow(window: window)
        } else {
            self.addNewWindow()
        }
    }

    @objc private func onNewTab(notification: SwiftUI.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }
        
        let fontSizeAny = notification.userInfo?[Ghostty.Notification.NewTabKey]
        let fontSize = fontSizeAny as? UInt8
        
        if fontSize != nil {
            // Add the new tab to the window with the given font size.
            self.addNewTab(to: window, withFontSize: fontSize)
        } else {
            // No font size specified, just add new tab.
            self.addNewTab(to: window)
        }
    }
    
    private func addNewTab(to window: NSWindow, withFontSize fontSize: UInt8? = nil) {
        guard let controller = createWindowController(withFontSize: fontSize) else { return }
        guard let newWindow = addManagedWindow(windowController: controller)?.window else { return  }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    private func createWindowController(withFontSize fontSize: UInt8? = nil) -> PrimaryWindowController? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        let window = PrimaryWindow.create(ghostty: ghostty, appDelegate: appDelegate, fontSize: fontSize)
        Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
        let controller = PrimaryWindowController(window: window)
        controller.windowManager = self
        return controller
    }

    private func addManagedWindow(windowController: PrimaryWindowController) -> ManagedWindow? {
        guard let window = windowController.window else { return nil }

        let pubClose = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { notification in
                guard let window = notification.object as? NSWindow else { return }
                self.removeWindow(window: window)
            }
        
        let managed = ManagedWindow(windowController: windowController, window: window, closePublisher: pubClose)
        managedWindows.append(managed)

        return managed
    }
    
    private func removeWindow(window: NSWindow) {
        self.managedWindows.removeAll(where: { $0.window === window })
    }
}
