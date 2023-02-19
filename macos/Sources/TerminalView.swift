import SwiftUI
import GhosttyKit

struct TerminalView: View {
    let app: ghostty_app_t
    @FocusState private var surfaceFocus: Bool
    @Environment(\.isKeyWindow) private var isKeyWindow: Bool
    @State private var title: String = "Ghostty"
    
    // This is true if the terminal is considered "focused". The terminal is focused if
    // it is both individually focused and the containing window is key.
    private var hasFocus: Bool { surfaceFocus && isKeyWindow }
    
    var body: some View {
        VStack {
            TerminalSurfaceView(app, hasFocus: hasFocus, title: $title)
                .focused($surfaceFocus)
                .navigationTitle(title)
        }
    }
}
