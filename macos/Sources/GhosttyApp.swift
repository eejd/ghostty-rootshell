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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    /// The current focused Ghostty surface in this app
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    
    var body: some Scene {
        WindowGroup {
            switch ghostty.readiness {
            case .loading:
                Text("Loading")
            case .error:
                ErrorView()
            case .ready:
                Ghostty.TerminalSplit()
                    .ghosttyApp(ghostty.app!)
            }
        }.commands {
            CommandGroup(after: .newItem) {
                Button("New Tab", action: newTab).keyboardShortcut("t", modifiers: [.command])
                Divider()
                Button("Close", action: close).keyboardShortcut("w", modifiers: [.command])
                Button("Close Window", action: closeWindow).keyboardShortcut("w", modifiers: [.command, .shift])
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
    
    func close() {
        guard let surfaceView = focusedSurface else { return }
        guard let surface = surfaceView.surface else { return }
        ghostty.requestClose(surface: surface)
    }
    
    func closeWindow() {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // See CursedMenuManager for more information.
    private var menuManager: CursedMenuManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])
        
        // Create our menu manager to create some custom menu items that
        // we can't create from SwiftUI.
        menuManager = CursedMenuManager()
    }
}

/// SwiftUI as of macOS 13.x provides no way to manage the default menu items that are created
/// as part of a WindowGroup. This class is prefixed with "Cursed" because this is a truly cursed
/// solution to the problem and I think its quite brittle. As soon as SwiftUI supports a better option
/// we should conditionally compile for that when supported.
///
/// The way this works is by setting up KVO on various menu objects and reacting to it. For example,
/// when SwiftUI tries to add a "Close" menu, we intercept it and delete it. Nice try!
private class CursedMenuManager {
    var mainToken: NSKeyValueObservation?
    var fileToken: NSKeyValueObservation?
    
    init() {
        // If the whole menu changed we want to setup our new KVO
        self.mainToken = NSApp.observe(\.mainMenu, options: .new) { app, change in
            self.onNewMenu()
        }
        
        // Initial setup
        onNewMenu()
    }
    
    private func onNewMenu() {
         guard let menu = NSApp.mainMenu else { return }
         guard let file = menu.item(withTitle: "File") else { return }
         guard let submenu = file.submenu else { return }
         fileToken = submenu.observe(\.items) { (_, _) in
             let remove = ["Close", "Close All"]
             
             // We look for the items in reverse since we're removing only the
             // ones SwiftUI inserts which are at the end. We make replacements
             // which we DON'T want deleted.
             let items = submenu.items.reversed()
             remove.forEach { title in
                 if let item = items.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                     submenu.removeItem(item)
                 }
             }
         }
    }
}
