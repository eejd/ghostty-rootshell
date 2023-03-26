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
                Ghostty.TerminalSplit(onClose: Self.closeWindow)
                    .ghosttyApp(ghostty.app!)
            }
        }
        .backport.defaultSize(width: 800, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab", action: Self.newTab).keyboardShortcut("t", modifiers: [.command])
                Divider()
                Button("Split Horizontally", action: splitHorizontally).keyboardShortcut("d", modifiers: [.command])
                Button("Split Vertically", action: splitVertically).keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Close", action: close).keyboardShortcut("w", modifiers: [.command])
                Button("Close Window", action: Self.closeWindow).keyboardShortcut("w", modifiers: [.command, .shift])
             }
            
            CommandGroup(before: .windowArrangement) {
                Divider()
                Button("Select Previous Split") { splitMoveFocus(direction: .previous) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Select Next Split") { splitMoveFocus(direction: .next) }
                    .keyboardShortcut("]", modifiers: .command)
                Menu("Select Split") {
                    Button("Select Split Above") { splitMoveFocus(direction: .top) }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button("Select Split Below") { splitMoveFocus(direction: .bottom) }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    Button("Select Split Left") { splitMoveFocus(direction: .left) }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Button("Select Split Right") { splitMoveFocus(direction: .right)}
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                }
                
                Divider()
            }
        }
        
        Settings {
            SettingsView()
        }
    }
    
    // Create a new tab in the currently active window
    static func newTab() {
        guard let currentWindow = NSApp.keyWindow else { return }
        guard let windowController = currentWindow.windowController else { return }
        windowController.newWindowForTab(nil)
        if let newWindow = NSApp.keyWindow, currentWindow != newWindow {
            currentWindow.addTabbedWindow(newWindow, ordered: .above)
        }
    }
    
    static func closeWindow() {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }
    
    func close() {
        guard let surfaceView = focusedSurface else {
            Self.closeWindow()
            return
        }
        
        guard let surface = surfaceView.surface else { return }
        ghostty.requestClose(surface: surface)
    }
    
    func splitHorizontally() {
        guard let surfaceView = focusedSurface else { return }
        guard let surface = surfaceView.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_RIGHT)
    }
    
    func splitVertically() {
        guard let surfaceView = focusedSurface else { return }
        guard let surface = surfaceView.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DOWN)
    }
    
    func splitMoveFocus(direction: Ghostty.SplitFocusDirection) {
        guard let surfaceView = focusedSurface else { return }
        guard let surface = surfaceView.surface else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
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
