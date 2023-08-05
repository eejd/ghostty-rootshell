import AppKit
import OSLog
import GhosttyKit

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // The application logger. We should probably move this at some point to a dedicated
    // class/struct but for now it lives here! 🤷‍♂️
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AppDelegate.self)
    )
    
    // confirmQuit published so other views can check whether quit needs to be confirmed.
    @Published var confirmQuit: Bool = false
    
    /// The ghostty global state. Only one per process.
    private var ghostty: Ghostty.AppState = Ghostty.AppState()
    
    /// Manages windows and tabs, ensuring they're allocated/deallocated correctly
    private var windowManager: PrimaryWindowManager!
    
    override init() {
        super.init()
        
        windowManager = PrimaryWindowManager(ghostty: self.ghostty)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // System settings overrides
        UserDefaults.standard.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])
        
        // Let's launch our first window.
        // TODO: we should detect if we restored windows and if so not launch a new window.
        windowManager.addInitialWindow()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = NSApplication.shared.windows
        if (windows.isEmpty) { return .terminateNow }
        
        // This probably isn't fully safe. The isEmpty check above is aspirational, it doesn't
        // quite work with SwiftUI because windows are retained on close. So instead we check
        // if there are any that are visible. I'm guessing this breaks under certain scenarios.
        if (windows.allSatisfy { !$0.isVisible }) { return .terminateNow }
        
        // If the user is shutting down, restarting, or logging out, we don't confirm quit.
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            if let why = event.attributeDescriptor(forKeyword: AEKeyword("why?")!) {
                switch (why.typeCodeValue) {
                case kAEShutDown:
                    fallthrough
                    
                case kAERestart:
                    fallthrough
                    
                case kAEReallyLogOut:
                    return .terminateNow
                    
                default:
                    break
                }
            }
        }
        
        // We have some visible window, and all our windows will watch the confirmQuit.
        confirmQuit = true
        return .terminateLater
    }
    
    @IBAction func newWindow(_ sender: Any?) {
        windowManager.addNewWindow()
    }
    
    @IBAction func newTab(_ sender: Any?) {
        windowManager.addNewTab()
    }

    @IBAction func closeWindow(_ sender: Any) {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }

    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface() else {
            self.closeWindow(self)
            return
        }

        ghostty.requestClose(surface: surface)
    }
    
    private func focusedSurface() -> ghostty_surface_t? {
        guard let window = NSApp.keyWindow as? PrimaryWindow else { return nil }
        return window.focusedSurfaceWrapper.surface
    }
    
    @IBAction func splitHorizontally(_ sender: Any) {
        guard let surface = focusedSurface() else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_RIGHT)
    }
    
    @IBAction func splitVertically(_ sender: Any) {
        guard let surface = focusedSurface() else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DOWN)
    }
    
    @IBAction func splitMoveFocusPrevious(_ sender: Any) {
        splitMoveFocus(direction: .previous)
    }
    
    @IBAction func splitMoveFocusNext(_ sender: Any) {
        splitMoveFocus(direction: .next)
    }
    
    @IBAction func splitMoveFocusAbove(_ sender: Any) {
        splitMoveFocus(direction: .top)
    }
    
    @IBAction func splitMoveFocusBelow(_ sender: Any) {
        splitMoveFocus(direction: .bottom)
    }
    
    @IBAction func splitMoveFocusLeft(_ sender: Any) {
        splitMoveFocus(direction: .left)
    }
    
    @IBAction func splitMoveFocusRight(_ sender: Any) {
        splitMoveFocus(direction: .right)
    }
    
    func splitMoveFocus(direction: Ghostty.SplitFocusDirection) {
        guard let surface = focusedSurface() else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
    }
}
