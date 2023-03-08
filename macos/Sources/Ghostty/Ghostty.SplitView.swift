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

            // See fixFocus comment, we have to run this whenever split changes.
            fixFocus()
        }
        
        func closeTopLeft() {
            assert(state.direction != .none)
            assert(state.bottomRight != nil)
            state.topLeft = state.bottomRight!
            state.direction = .none
            
            // See fixFocus comment, we have to run this whenever split changes.
            fixFocus()
        }
        
        func closeBottomRight() {
            assert(state.direction != .none)
            assert(state.bottomRight != nil)
            state.bottomRight = nil
            state.direction = .none
            
            // See fixFocus comment, we have to run this whenever split changes.
            fixFocus()
        }

        /// There is a bug I can't figure out where when changing the split state, the terminal view
        /// will lose focus. There has to be some nice SwiftUI-native way to fix this but I can't
        /// figure it out so we're going to do this hacky thing to bring focus back to the terminal
        /// that should have it.
        private func fixFocus() {
            DispatchQueue.main.async {
                // The view we want to focus
                var view = state.topLeft
                if let right = state.bottomRight { view = right }
                
                // If the callback runs before the surface is attached to a view
                // then the window will be nil. We just reschedule in that case.
                guard let window = view.window else {
                    self.fixFocus()
                    return
                }
                
                _ = state.topLeft.resignFirstResponder()
                _ = state.bottomRight?.resignFirstResponder()
                window.makeFirstResponder(view)
            }
        }
        
        private func onNewSplit(notification: SwiftUI.Notification) {
            guard let directionAny = notification.userInfo?["direction"] else { return }
            guard let direction = directionAny as? ghostty_split_direction_e else { return }
            switch (direction) {
            case GHOSTTY_SPLIT_RIGHT:
                split(to: .horizontal)
                
            case GHOSTTY_SPLIT_DOWN:
                split(to: .vertical)
                
            default:
                break
            }
        }

        var body: some View {
            switch (state.direction) {
            case .none:
                let pub = NotificationCenter.default.publisher(for: Ghostty.Notification.ghosttyNewSplit, object: state.topLeft)
                SurfaceWrapper(surfaceView: state.topLeft)
                    .onReceive(pub) { onNewSplit(notification: $0) }
            case .horizontal:
                SplitView(.horizontal, left: {
                    TerminalSplitChild(app, topLeft: state.topLeft)
                }, right: {
                    TerminalSplitChild(app, topLeft: state.bottomRight!)
                })
            case .vertical:
                SplitView(.vertical, left: {
                    TerminalSplitChild(app, topLeft: state.topLeft)
                }, right: {
                    TerminalSplitChild(app, topLeft: state.bottomRight!)
                })
            }
        }
    }

}
