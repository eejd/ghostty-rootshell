import SwiftUI
import GhosttyKit

struct TerminalView: View {
    let app: ghostty_app_t
    @FocusState private var surfaceFocus: Bool
    @Environment(\.isKeyWindow) private var isKeyWindow: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var title: String = "Ghostty"
    
    // This is true if the terminal is considered "focused". The terminal is focused if
    // it is both individually focused and the containing window is key.
    private var hasFocus: Bool { surfaceFocus && isKeyWindow }
    
    var body: some View {
        TerminalSurfaceView(app, hasFocus: hasFocus, title: $title)
            .focused($surfaceFocus)
            .navigationTitle(title)
    }
}
