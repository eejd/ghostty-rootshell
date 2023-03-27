import SwiftUI
import GhosttyKit

struct ContentView: View {
    let ghostty: Ghostty.AppState
    
    @EnvironmentObject private var appDelegate: AppDelegate
    
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
            Ghostty.TerminalSplit(onClose: Self.closeWindow)
                .ghosttyApp(ghostty.app!)
                .confirmationDialog(
                    "Quit Ghostty?",
                    isPresented: $appDelegate.confirmQuit) {
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
