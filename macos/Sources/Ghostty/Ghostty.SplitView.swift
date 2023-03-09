import SwiftUI
import GhosttyKit

extension Ghostty {
    /// A spittable terminal view is one where the terminal allows for "splits" (vertical and horizontal) within the
    /// view. The terminal starts in the unsplit state (a plain ol' TerminalView) but responds to changes to the
    /// split direction by splitting the terminal.
    struct TerminalSplit: View {
        @Environment(\.ghosttyApp) private var app
        @FocusedValue(\.ghosttySurfaceTitle) private var surfaceTitle: String?
        
        var body: some View {
            if let app = app {
                TerminalSplitContainer(app: app)
                    .navigationTitle(surfaceTitle ?? "Ghostty")
            }
        }
    }
    
    private struct TerminalSplitPane: View {
        @ObservedObject var surfaceView: SurfaceView
        @Binding var requestSplit: SplitViewDirection?
        @Binding var requestClose: Bool

        var body: some View {
            let pub = NotificationCenter.default.publisher(for: Notification.ghosttyNewSplit, object: surfaceView)
            let pubClose = NotificationCenter.default.publisher(for: Notification.ghosttyCloseSurface, object: surfaceView)
            SurfaceWrapper(surfaceView: surfaceView)
                .onReceive(pub) { onNewSplit(notification: $0) }
                .onReceive(pubClose) { _ in requestClose = true }
        }
        
        private func onNewSplit(notification: SwiftUI.Notification) {
            guard let directionAny = notification.userInfo?["direction"] else { return }
            guard let direction = directionAny as? ghostty_split_direction_e else { return }
            switch (direction) {
            case GHOSTTY_SPLIT_RIGHT:
                requestSplit = .horizontal
                
            case GHOSTTY_SPLIT_DOWN:
                requestSplit = .vertical
                
            default:
                break
            }
        }
    }
    
    private struct TerminalSplitContainer: View {
        let app: ghostty_app_t
        var parentClose: Binding<Bool>? = nil
        @State private var direction: SplitViewDirection? = nil
        @State private var proposedDirection: SplitViewDirection? = nil
        @State private var closeTopLeft: Bool = false
        @State private var closeBottomRight: Bool = false
        @StateObject private var panes: PaneState
        
        class PaneState: ObservableObject {
            @Published var topLeft: SurfaceView
            @Published var bottomRight: SurfaceView? = nil
            
            /// Initialize the view state for the first time. This will create our topLeft view from new.
            init(_ app: ghostty_app_t) {
                self.topLeft = SurfaceView(app)
            }
            
            /// Initialize the view state using an existing top left. This is usually used when a split happens and
            /// the child view inherits the top left.
            init(topLeft: SurfaceView) {
                self.topLeft = topLeft
            }
        }
        
        init(app: ghostty_app_t) {
            self.app = app
            _panes = StateObject(wrappedValue: PaneState(app))
        }
        
        init(app: ghostty_app_t, parentClose: Binding<Bool>, topLeft: SurfaceView) {
            self.app = app
            self.parentClose = parentClose
            _panes = StateObject(wrappedValue: PaneState(topLeft: topLeft))
        }

        var body: some View {
            if let direction = self.direction {
                SplitView(direction, left: {
                    TerminalSplitContainer(
                        app: app,
                        parentClose: $closeTopLeft,
                        topLeft: panes.topLeft
                    )
                    .onChange(of: closeTopLeft) { value in
                        guard value else { return }
                        
                        // Move our bottom to our top and reset all of our state
                        panes.topLeft = panes.bottomRight!
                        panes.bottomRight = nil
                        self.direction = nil
                        closeTopLeft = false
                        closeBottomRight = false
                        
                        // See fixFocus comment, we have to run this whenever split changes.
                        fixFocus()
                    }
                }, right: {
                    TerminalSplitContainer(
                        app: app,
                        parentClose: $closeBottomRight,
                        topLeft: panes.bottomRight!
                    )
                    .onChange(of: closeBottomRight) { value in
                        guard value else { return }
                        
                        // Move our bottom to our top and reset all of our state
                        panes.bottomRight = nil
                        self.direction = nil
                        closeTopLeft = false
                        closeBottomRight = false
                        
                        // See fixFocus comment, we have to run this whenever split changes.
                        fixFocus()
                    }
                })
            } else {
                TerminalSplitPane(surfaceView: panes.topLeft, requestSplit: $proposedDirection, requestClose: $closeTopLeft)
                    .onChange(of: proposedDirection) { value in
                        guard let newDirection = value else { return }
                        split(to: newDirection)
                    }
                    .onChange(of: closeTopLeft) { value in
                        guard value else { return }
                        self.parentClose?.wrappedValue = value
                    }
            }
        }
        
        private func split(to: SplitViewDirection) {
            assert(direction == nil)
            
            // Make the split the desired value
            direction = to
            
            // Create the new split which always goes to the bottom right.
            panes.bottomRight = SurfaceView(app)

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
                var view = panes.topLeft
                if let right = panes.bottomRight { view = right }
                
                // If the callback runs before the surface is attached to a view
                // then the window will be nil. We just reschedule in that case.
                guard let window = view.window else {
                    self.fixFocus()
                    return
                }
                
                _ = panes.topLeft.resignFirstResponder()
                _ = panes.bottomRight?.resignFirstResponder()
                window.makeFirstResponder(view)
            }
        }
    }
}
