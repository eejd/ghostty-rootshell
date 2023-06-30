import Cocoa
import Combine

// WindowService manages the windows and tabs in the application.
// It keeps references to windows and cleans them up when they're cloned.
//
// It is based on the patterns presented in this blog post:
// https://christiantietze.de/posts/2019/07/nswindow-tabbing-multiple-nswindowcontroller/
class WindowService {
    struct ManagedWindow {
        let windowController: NSWindowController
        
        let window: NSWindow
        
        let closePublisher: AnyCancellable
    }

    private var ghostty: Ghostty.AppState
    private var managedWindows: [ManagedWindow] = []
    
    init(ghostty: Ghostty.AppState) {
        self.ghostty = ghostty
        
        addInitialWindow()
    }
    
    private func addInitialWindow() {
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
    
    func addNewTab() {
        guard let existingWindow = mainWindow() else { return }
        guard let controller = createWindowController() else { return }
        guard let newWindow = addManagedWindow(windowController: controller)?.window else { return  }
        existingWindow.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }
    
    /// Returns the main window of the managed window stack.
    /// Falls back the first element if no window is main.
    private func mainWindow() -> NSWindow? {
        let mainManagedWindow = managedWindows.first { $0.window.isMainWindow }
        return (mainManagedWindow ?? managedWindows.first).map { $0.window }
    }

    private func createWindowController() -> WindowController? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return WindowController.create(ghosttyApp: self.ghostty, appDelegate: appDelegate)
    }

    private func addManagedWindow(windowController: WindowController) -> ManagedWindow? {
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
