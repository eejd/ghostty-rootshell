import SwiftUI
import GhosttyKit

extension Ghostty {
    /// A spittable terminal view is one where the terminal allows for "splits" (vertical and horizontal) within the
    /// view. The terminal starts in the unsplit state (a plain ol' TerminalView) but responds to changes to the
    /// split direction by splitting the terminal.
    struct TerminalSplit: View {
        @Environment(\.ghosttyApp) private var app
        
        var body: some View {
            if let app = app {
                TerminalSplitChild(app)
            }
        }
    }
    
    private struct TerminalSplitChild: View {
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
            @Published var topLeft: Ghostty.SurfaceView
            
            /// The bottom or right view. This can be nil if the direction == .none.
            @Published var bottomRight: Ghostty.SurfaceView? = nil
            
            /// Initialize the view state for the first time. This will create our topLeft view from new.
            init(_ app: ghostty_app_t) {
                self.topLeft = Ghostty.SurfaceView(app)
            }
            
            /// Initialize the view state using an existing top left. This is usually used when a split happens and
            /// the child view inherits the top left.
            init(topLeft: Ghostty.SurfaceView) {
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
        
        init(_ app: ghostty_app_t, topLeft: Ghostty.SurfaceView) {
            self.app = app
            _state = StateObject(wrappedValue: ViewState(topLeft: topLeft))
        }
        
        func split(to: Direction) {
            assert(to != .none)
            assert(state.direction == .none)
            
            // Make the split the desired value
            state.direction = to
            
            // Create the new split which always goes to the bottom right.
            state.bottomRight = Ghostty.SurfaceView(app)
        }
        
        func closeTopLeft() {
            assert(state.direction != .none)
            assert(state.bottomRight != nil)
            state.topLeft = state.bottomRight!
            state.direction = .none
            focusedSide = .TopLeft
        }
        
        func closeBottomRight() {
            assert(state.direction != .none)
            assert(state.bottomRight != nil)
            state.bottomRight = nil
            state.direction = .none
            focusedSide = .TopLeft
        }

        var body: some View {
            switch (state.direction) {
            case .none:
                VStack {
                    HStack {
                        Button("Split Horizontal") { split(to: .horizontal) }
                        Button("Split Vertical") { split(to: .vertical) }
                    }
                    
                    SurfaceWrapper(surfaceView: state.topLeft)
                        .focused($focusedSide, equals: .TopLeft)
                }
            case .horizontal:
                VStack {
                    HStack {
                        Button("Close Left") { closeTopLeft() }
                        Button("Close Right") { closeBottomRight() }
                    }
                    
                    SplitView(.horizontal, left: {
                        TerminalSplitChild(app, topLeft: state.topLeft)
                            .focused($focusedSide, equals: .TopLeft)
                    }, right: {
                        TerminalSplitChild(app, topLeft: state.bottomRight!)
                            .focused($focusedSide, equals: .BottomRight)
                    })
                }
            case .vertical:
                VStack {
                    HStack {
                        Button("Close Top") { closeTopLeft() }
                        Button("Close Bottom") { closeBottomRight() }
                    }
                    
                    SplitView(.vertical, left: {
                        TerminalSplitChild(app, topLeft: state.topLeft)
                            .focused($focusedSide, equals: .TopLeft)
                    }, right: {
                        TerminalSplitChild(app, topLeft: state.bottomRight!)
                            .focused($focusedSide, equals: .BottomRight)
                    })
                }
            }
        }
    }

}
