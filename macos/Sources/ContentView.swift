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
            let confirmQuitting = Binding<Bool>(get: {
                self.appDelegate.confirmQuit && (self.window?.isKeyWindow ?? false)
            }, set: {
                self.appDelegate.confirmQuit = $0
            })
                                                        
            Ghostty.TerminalSplit(onClose: Self.closeWindow)
                .ghosttyApp(ghostty.app!)
                .background(WindowAccessor(window: $window))
                .confirmationDialog(
                    "Quit Ghostty?",
                    isPresented: confirmQuitting) {
                        Button("Close Ghostty", role: .destructive) {
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
}
