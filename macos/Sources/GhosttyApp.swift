import OSLog
import SwiftUI
import GhosttyKit

@main
struct GhosttyApp: App {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: GhosttyApp.self)
    )
    
    /// The ghostty global state. Only one per process.
    @StateObject private var ghostty = Ghostty.AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate;
    
    var body: some Scene {
        WindowGroup {
            switch ghostty.readiness {
            case .loading:
                Text("Loading")
            case .error:
                ErrorView()
            case .ready:
                Ghostty.TerminalSplitView()
                    .ghosttyApp(ghostty.app!)
            }
        }.commands {
            CommandGroup(after: .newItem) {
                Button("New Tab", action: newTab).keyboardShortcut("t", modifiers: [.command])
            }
        }
        
        Settings {
            SettingsView()
        }
    }
    
    // Create a new tab in the currently active window
    func newTab() {
        guard let currentWindow = NSApp.keyWindow else { return }
        guard let windowController = currentWindow.windowController else { return }
        windowController.newWindowForTab(nil)
        if let newWindow = NSApp.keyWindow, currentWindow != newWindow {
            currentWindow.addTabbedWindow(newWindow, ordered: .above)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])
    }
}
