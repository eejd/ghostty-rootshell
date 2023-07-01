import SwiftUI
import GhosttyKit

struct ContentView: View {
    let ghostty: Ghostty.AppState
    
    // We need access to our app delegate to know if we're quitting or not.
    @EnvironmentObject private var appDelegate: AppDelegate
    
    // We need access to our window to know if we're the key window to determine
    // if we show the quit confirmation or not.
    @State private var window: NSWindow?
    
    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
                .onChange(of: appDelegate.confirmQuit) { value in
                    guard value else { return }
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
        case .error:
            ErrorView()
                .onChange(of: appDelegate.confirmQuit) { value in
                    guard value else { return }
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
        case .ready:
            let center = NotificationCenter.default
            let gotoTab = center.publisher(for: Ghostty.Notification.ghosttyGotoTab)
            
            let confirmQuitting = Binding<Bool>(get: {
                self.appDelegate.confirmQuit && (self.window?.isKeyWindow ?? false)
            }, set: {
                self.appDelegate.confirmQuit = $0
            })
                                                        
            Ghostty.TerminalSplit(onClose: Self.closeWindow)
                .ghosttyApp(ghostty.app!)
                .background(WindowAccessor(window: $window))
                .onReceive(gotoTab) { onGotoTab(notification: $0) }
                .confirmationDialog(
                    "Quit Ghostty?",
                    isPresented: confirmQuitting) {
                        Button("Close Ghostty") {
                            NSApplication.shared.reply(toApplicationShouldTerminate: true)
                        }
                        .keyboardShortcut(.defaultAction)
                        
                        Button("Cancel", role: .cancel) {
                            NSApplication.shared.reply(toApplicationShouldTerminate: false)
                        }
                        .keyboardShortcut(.cancelAction)
                    } message: {
                        Text("All terminal sessions will be terminated.")
                    }
        }
    }
    
    static func closeWindow() {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }
        
    private func onGotoTab(notification: SwiftUI.Notification) {
        // Notification center indiscriminately sends to every subscriber (makes sense)
        // but we only want to process this once. In order to process it once lets only
        // handle it if we're the focused window.
        guard let window = self.window else { return }
        guard window.isKeyWindow else { return }
        
        // Get the tab index from the notification
        guard let tabIndexAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabIndex = tabIndexAny as? Int32 else { return }
        
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows
        
        // Tabs are 0-indexed here, so we subtract one from the key the user hit.
        let adjustedIndex = Int(tabIndex - 1);
        guard adjustedIndex >= 0 && adjustedIndex < tabbedWindows.count else { return }
        
        let targetWindow = tabbedWindows[adjustedIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }
}
