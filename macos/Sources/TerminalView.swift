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
        // We use a GeometryReader to get the frame bounds so that our metal surface
        // is up to date. See TerminalSurfaceView for why we don't use the NSView
        // resize callback.
        GeometryReader { geo in
            TerminalSurface(app, hasFocus: hasFocus, size: geo.size, title: $title)
                .focused($surfaceFocus)
                .navigationTitle(title)
        }
    }
}

/// A spittable terminal view is one where the terminal allows for "splits" (vertical and horizontal) within the
/// view. The terminal starts in the unsplit state (a plain ol' TerminalView) but responds to changes to the
/// split direction by splitting the terminal.
struct TerminalSplittableView: View {
    enum Direction {
        case none
        case vertical
        case horizontal
    }
    
    enum Side: Hashable {
        case TopLeft
        case BottomRight
    }
    
    @FocusState private var focusedSide: Side?
    
    let app: ghostty_app_t
    
    /// Direction of the current split. If this is "nil" then the terminal is not currently split at all.
    @State var splitDirection: Direction = .none

    var body: some View {
        switch (splitDirection) {
        case .none:
            VStack {
                HStack {
                    Button("Split Horizontal") { splitDirection = .horizontal }
                    Button("Split Vertical") { splitDirection = .vertical }
                }
                
                TerminalView(app: app)
                    .focused($focusedSide, equals: .TopLeft)
            }
        case .horizontal:
            VStack {
                HStack {
                    Button("Close Left") { splitDirection = .none }
                    Button("Close Right") { splitDirection = .none }
                }
                
                HSplitView {
                    TerminalSplittableView(app: app)
                        .focused($focusedSide, equals: .TopLeft)
                    TerminalSplittableView(app: app)
                        .focused($focusedSide, equals: .BottomRight)
                }
            }
        case .vertical:
            VSplitView {
                TerminalSplittableView(app: app)
                    .focused($focusedSide, equals: .TopLeft)
                TerminalSplittableView(app: app)
                    .focused($focusedSide, equals: .BottomRight)
            }
        }
    }
}
