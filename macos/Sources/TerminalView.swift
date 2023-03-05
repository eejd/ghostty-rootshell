import SwiftUI
import GhosttyKit

struct TerminalView: View {
    // The surface to create a view for. This must be created upstream. As long as this
    // remains the same, the surface that is being rendered remains the same.
    @ObservedObject var surfaceView: TerminalSurfaceView
    
    @FocusState private var surfaceFocus: Bool
    @Environment(\.isKeyWindow) private var isKeyWindow: Bool
    
    // This is true if the terminal is considered "focused". The terminal is focused if
    // it is both individually focused and the containing window is key.
    private var hasFocus: Bool { surfaceFocus && isKeyWindow }
    
    // Initialize a TerminalView with a new surface view state.
    init(_ app: ghostty_app_t) {
        self.surfaceView = TerminalSurfaceView(app)
    }
    
    init(surface: TerminalSurfaceView) {
        self.surfaceView = surface
    }
    
    var body: some View {
        // We use a GeometryReader to get the frame bounds so that our metal surface
        // is up to date. See TerminalSurfaceView for why we don't use the NSView
        // resize callback.
        GeometryReader { geo in
            TerminalSurface(view: surfaceView, hasFocus: hasFocus, size: geo.size)
                .focused($surfaceFocus)
                .navigationTitle(surfaceView.title)
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
    
    let app: ghostty_app_t;
    
    @State private var topLeft: TerminalSurfaceView
    
    /// The bottom or right surface. This is private because in a splittable view it is only possible that we set
    /// this, because it is triggered from a split event.
    @State private var bottomRight: TerminalSurfaceView? = nil
    
    /// Direction of the current split. If this is "nil" then the terminal is not currently split at all.
    @State private var splitDirection: Direction = .none
    
    init(_ app: ghostty_app_t) {
        self.app = app
        _topLeft = State(wrappedValue: TerminalSurfaceView(app))
    }
    
    init(_ app: ghostty_app_t, topLeft: TerminalSurfaceView) {
        self.app = app
        _topLeft = State(wrappedValue: topLeft)
    }
    
    func split(to: Direction) {
        assert(to != .none)
        assert(splitDirection == .none)
        splitDirection = to
        bottomRight = TerminalSurfaceView(app)
    }
    
    func closeTopLeft() {
        assert(splitDirection != .none)
        assert(bottomRight != nil)
        topLeft = bottomRight!
        splitDirection = .none
    }
    
    func closeBottomRight() {
        assert(splitDirection != .none)
        assert(bottomRight != nil)
        bottomRight = nil
        splitDirection = .none
    }

    var body: some View {
        switch (splitDirection) {
        case .none:
            VStack {
                HStack {
                    Button("Split Horizontal") { split(to: .horizontal) }
                    Button("Split Vertical") { split(to: .vertical) }
                }
                
                TerminalView(surface: topLeft)
                    .focused($focusedSide, equals: .TopLeft)
            }
        case .horizontal:
            VStack {
                HStack {
                    Button("Close Left") { closeTopLeft() }
                    Button("Close Right") { closeBottomRight() }
                }
                
                HSplitView {
                    TerminalSplittableView(app, topLeft: topLeft)
                        .focused($focusedSide, equals: .TopLeft)
                    TerminalSplittableView(app, topLeft: bottomRight!)
                        .focused($focusedSide, equals: .BottomRight)
                }
            }
        case .vertical:
            VStack {
                HStack {
                    Button("Close Top") { closeTopLeft() }
                    Button("Close Bottom") { closeBottomRight() }
                }
                
                VSplitView {
                    TerminalSplittableView(app, topLeft: topLeft)
                        .focused($focusedSide, equals: .TopLeft)
                    TerminalSplittableView(app, topLeft: bottomRight!)
                        .focused($focusedSide, equals: .BottomRight)
                }
            }
        }
    }
}
