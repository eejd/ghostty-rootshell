import SwiftUI
import GhosttyKit

struct ContentView: View {
    let ghostty: Ghostty.AppState
    
    // We need access to our app delegate to know if we're quitting or not.
    // Make sure to use `@ObservedObject` so we can keep track of `appDelegate.confirmQuit`.
    @ObservedObject var appDelegate: AppDelegate
    
    // We need this to report back up the app controller which surface in this view is focused.
    let focusedSurfaceWrapper: FocusedSurfaceWrapper
    
    // We need access to our window to know if we're the key window to determine
    // if we show the quit confirmation or not.
    @State private var window: NSWindow?
    
    // This handles non-native fullscreen
    @State private var fsHandler = FullScreenHandler()
    
    // This seems like a crutch after switchign from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool
    
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    
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
            let toggleFullscreen = center.publisher(for: Ghostty.Notification.ghosttyToggleFullscreen)
            
            let confirmQuitting = Binding<Bool>(get: {
                self.appDelegate.confirmQuit && (self.window?.isKeyWindow ?? false)
            }, set: {
                self.appDelegate.confirmQuit = $0
            })
            
            Ghostty.TerminalSplit(onClose: Self.closeWindow)
                .ghosttyApp(ghostty.app!)
                .background(WindowAccessor(window: $window))
                .onReceive(gotoTab) { onGotoTab(notification: $0) }
                .onReceive(toggleFullscreen) { onToggleFullscreen(notification: $0) }
                .focused($focused)
                .onAppear { self.focused = true }
                .onChange(of: focusedSurface) { newValue in
                    self.focusedSurfaceWrapper.surface = newValue?.surface
                }
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

    private func onToggleFullscreen(notification: SwiftUI.Notification) {
        // Just like in `onGotoTab`, we might receive this multiple times. But
        // it's fine, because `toggleFullscreen` should only apply to the
        // currently focused window.
        guard let window = self.window else { return }
        guard window.isKeyWindow else { return }

        // Check whether we use non-native fullscreen
        guard let useNonNativeFullscreenAny = notification.userInfo?[Ghostty.Notification.NonNativeFullscreenKey] else { return }
        guard let useNonNativeFullscreen = useNonNativeFullscreenAny as? Bool else { return }

        self.fsHandler.toggleFullscreen(window: window, nonNativeFullscreen: useNonNativeFullscreen)
        // After toggling fullscreen we need to focus the terminal again.
        self.focused = true
    }
}
