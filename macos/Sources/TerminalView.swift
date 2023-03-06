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
    
    /// The stored state between invocations.
    class ViewState: ObservableObject {
        /// The direction of the split currently
        @Published var direction: Direction = .none
        
        /// The top or left view. This is always set.
        @Published var topLeft: TerminalSurfaceView
        
        /// The bottom or right view. This can be nil if the direction == .none.
        @Published var bottomRight: TerminalSurfaceView? = nil
        
        /// Initialize the view state for the first time. This will create our topLeft view from new.
        init(_ app: ghostty_app_t) {
            self.topLeft = TerminalSurfaceView(app)
        }
        
        /// Initialize the view state using an existing top left. This is usually used when a split happens and
        /// the child view inherits the top left.
        init(topLeft: TerminalSurfaceView) {
            self.topLeft = topLeft
        }
    }
    
    let app: ghostty_app_t
    @StateObject private var state: ViewState
    @FocusState private var focusedSide: Side?
    
    init(_ app: ghostty_app_t) {
        self.app = app
        _state = StateObject(wrappedValue: ViewState(app))
    }
    
    init(_ app: ghostty_app_t, topLeft: TerminalSurfaceView) {
        self.app = app
        _state = StateObject(wrappedValue: ViewState(topLeft: topLeft))
    }
    
    func split(to: Direction) {
        assert(to != .none)
        assert(state.direction == .none)
        
        // Make the split the desired value
        state.direction = to
        
        // Create the new split which always goes to the bottom right.
        state.bottomRight = TerminalSurfaceView(app)
    }
    
    func closeTopLeft() {
        assert(state.direction != .none)
        assert(state.bottomRight != nil)
        state.topLeft = state.bottomRight!
        state.direction = .none
    }
    
    func closeBottomRight() {
        assert(state.direction != .none)
        assert(state.bottomRight != nil)
        state.bottomRight = nil
        state.direction = .none
    }

    var body: some View {
        switch (state.direction) {
        case .none:
            VStack {
                HStack {
                    Button("Split Horizontal") { split(to: .horizontal) }
                    Button("Split Vertical") { split(to: .vertical) }
                }
                
                TerminalView(surface: state.topLeft)
                    .focused($focusedSide, equals: .TopLeft)
            }
        case .horizontal:
            VStack {
                HStack {
                    Button("Close Left") { closeTopLeft() }
                    Button("Close Right") { closeBottomRight() }
                }
                
                HSplitView {
                    TerminalSplittableView(app, topLeft: state.topLeft)
                        .focused($focusedSide, equals: .TopLeft)
                    TerminalSplittableView(app, topLeft: state.bottomRight!)
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
                    TerminalSplittableView(app, topLeft: state.topLeft)
                        .focused($focusedSide, equals: .TopLeft)
                    TerminalSplittableView(app, topLeft: state.bottomRight!)
                        .focused($focusedSide, equals: .BottomRight)
                }
            }
        }
    }
}
