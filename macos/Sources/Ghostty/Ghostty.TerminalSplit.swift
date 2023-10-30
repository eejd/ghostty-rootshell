import SwiftUI
import GhosttyKit

extension Ghostty {
    /// A spittable terminal view is one where the terminal allows for "splits" (vertical and horizontal) within the
    /// view. The terminal starts in the unsplit state (a plain ol' TerminalView) but responds to changes to the
    /// split direction by splitting the terminal.
    ///
    /// This also allows one split to be "zoomed" at any time.
    struct TerminalSplit2: View {
        /// The current state of the root node. This can be set to nil when all surfaces are closed.
        @Binding var node: SplitNode?

        /// Non-nil if one of the surfaces in the split tree is currently "zoomed." A zoomed surface
        /// becomes "full screen" on the split tree.
        @State private var zoomedSurface: SurfaceView? = nil

        var body: some View {
            ZStack {
                TerminalSplitRoot2(
                    node: $node,
                    zoomedSurface: $zoomedSurface
                )

                // If we have a zoomed surface, we overlay that on top of our split
                // root. Our split root will become clear when there is a zoomed
                // surface. We need to keep the split root around so that we don't
                // lose all of the surface state so this must be a ZStack.
                if let surfaceView = zoomedSurface {
                    InspectableSurface(surfaceView: surfaceView)
                }
            }
            .focusedValue(\.ghosttySurfaceZoomed, zoomedSurface != nil)
        }
    }
    
    /// The root of a split tree. This sets up the initial SplitNode state and renders. There is only ever
    /// one of these in a split tree.
    private struct TerminalSplitRoot2: View {
        /// The root node that we're rendering. This will be set to nil if all the surfaces in this tree close.
        @Binding var node: SplitNode?

        /// Keeps track of whether we're in a zoomed split state or not. If one of the splits we own
        /// is in the zoomed state, we clear our body since we expect a zoomed split to overlay
        /// this one.
        @Binding var zoomedSurface: SurfaceView?

        @FocusedValue(\.ghosttySurfaceTitle) private var surfaceTitle: String?

        var body: some View {
            let center = NotificationCenter.default
            let pubZoom = center.publisher(for: Notification.didToggleSplitZoom)

            // If we're zoomed, we don't render anything, we are transparent. This
            // ensures that the View stays around so we don't lose our state, but
            // also that the zoomed view on top can see through if background transparency
            // is enabled.
            if (zoomedSurface == nil) {
                ZStack {
                    switch (node) {
                    case nil:
                        Color(.clear)
                        
                    case .noSplit(let leaf):
                        TerminalSplitLeaf2(
                            leaf: leaf,
                            neighbors: .empty,
                            node: $node
                        )

                    case .horizontal(let container):
                        TerminalSplitContainer2(
                            direction: .horizontal,
                            neighbors: .empty,
                            node: $node,
                            container: container
                        )
                        .onReceive(pubZoom) { onZoom(notification: $0) }

                    case .vertical(let container):
                        TerminalSplitContainer2(
                            direction: .vertical,
                            neighbors: .empty,
                            node: $node,
                            container: container
                        )
                        .onReceive(pubZoom) { onZoom(notification: $0) }
                    }
                }
                .navigationTitle(surfaceTitle ?? "Ghostty")
            } else {
                // On these events we want to reset the split state and call it.
                let pubSplit = center.publisher(for: Notification.ghosttyNewSplit, object: zoomedSurface!)
                let pubClose = center.publisher(for: Notification.ghosttyCloseSurface, object: zoomedSurface!)
                let pubFocus = center.publisher(for: Notification.ghosttyFocusSplit, object: zoomedSurface!)

                ZStack {}
                    .onReceive(pubZoom) { onZoomReset(notification: $0) }
                    .onReceive(pubSplit) { onZoomReset(notification: $0) }
                    .onReceive(pubClose) { onZoomReset(notification: $0) }
                    .onReceive(pubFocus) { onZoomReset(notification: $0) }
            }
        }
        
        func onZoom(notification: SwiftUI.Notification) {
            // Our node must be split to receive zooms. You can't zoom an unsplit terminal.
            if case .noSplit = node {
                preconditionFailure("TerminalSplitRoom must not be zoom-able if no splits exist")
            }

            // Make sure the notification has a surface and that this window owns the surface.
            guard let surfaceView = notification.object as? SurfaceView else { return }
            guard node?.contains(view: surfaceView) ?? false else { return }

            // We are in the zoomed state.
            zoomedSurface = surfaceView

            // See onZoomReset, same logic.
            DispatchQueue.main.async { Ghostty.moveFocus(to: surfaceView) }
        }

        func onZoomReset(notification: SwiftUI.Notification) {
            // Make sure the notification has a surface and that this window owns the surface.
            guard let surfaceView = notification.object as? SurfaceView else { return }
            guard zoomedSurface == surfaceView else { return }

            // We are now unzoomed
            zoomedSurface = nil

            // We need to stay focused on this view, but the view is going to change
            // superviews. We need to do this async so it happens on the next event loop
            // tick.
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: surfaceView)

                // If the notification is not a toggle zoom notification, we want to re-publish
                // it after a short delay so that the split tree has a chance to re-establish
                // so the proper view gets this notification.
                if (notification.name != Notification.didToggleSplitZoom) {
                    // We have to wait ANOTHER tick since we just established.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(notification)
                    }
                }
            }
        }
    }
    
    /// A noSplit leaf node of a split tree.
    private struct TerminalSplitLeaf2: View {
        /// The leaf to draw the surface for.
        let leaf: SplitNode.Leaf

        /// The neighbors, used for navigation.
        let neighbors: SplitNode.Neighbors

        /// The SplitNode that the leaf belongs to. This will be set to nil but when leaf is closed.
        @Binding var node: SplitNode?

        var body: some View {
            let center = NotificationCenter.default
            let pub = center.publisher(for: Notification.ghosttyNewSplit, object: leaf.surface)
            let pubClose = center.publisher(for: Notification.ghosttyCloseSurface, object: leaf.surface)
            let pubFocus = center.publisher(for: Notification.ghosttyFocusSplit, object: leaf.surface)

            InspectableSurface(surfaceView: leaf.surface, isSplit: !neighbors.isEmpty())
                .onReceive(pub) { onNewSplit(notification: $0) }
                .onReceive(pubClose) { onClose(notification: $0) }
                .onReceive(pubFocus) { onMoveFocus(notification: $0) }
        }

        private func onClose(notification: SwiftUI.Notification) {
            var processAlive = false
            if let valueAny = notification.userInfo?["process_alive"] {
                if let value = valueAny as? Bool {
                    processAlive = value
                }
            }

            // If the child process is not alive, then we exit immediately
            guard processAlive else {
                node = nil
                return
            }
            
            // If we don't have a window to attach our modal to, we also exit immediately.
            // This should NOT happen.
            guard let window = leaf.surface.window else {
                node = nil
                return
            }
            
            // Confirm close. We use an NSAlert instead of a SwiftUI confirmationDialog
            // due to SwiftUI bugs (see Ghostty #560). To repeat from #560, the bug is that
            // confirmationDialog allows the user to Cmd-W close the alert, but when doing
            // so SwiftUI does not update any of the bindings to note that window is no longer
            // being shown, and provides no callback to detect this.
            let alert = NSAlert()
            alert.messageText = "Close Terminal?"
            alert.informativeText = "The terminal still has a running process. If you close the " +
                "terminal the process will be killed."
            alert.addButton(withTitle: "Close the Terminal")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window, completionHandler: { response in
                switch (response) {
                case .alertFirstButtonReturn:
                    node = nil
                    
                default:
                    break
                }
            })
        }

        private func onNewSplit(notification: SwiftUI.Notification) {
            let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
            let config = configAny as? SurfaceConfiguration

            // Determine our desired direction
            guard let directionAny = notification.userInfo?["direction"] else { return }
            guard let direction = directionAny as? ghostty_split_direction_e else { return }
            var splitDirection: SplitViewDirection
            switch (direction) {
            case GHOSTTY_SPLIT_RIGHT:
                splitDirection = .horizontal

            case GHOSTTY_SPLIT_DOWN:
                splitDirection = .vertical

            default:
                return
            }

            // Setup our new container since we are now split
            let container = SplitNode.Container(from: leaf, baseConfig: config)

            // Depending on the direction, change the parent node. This will trigger
            // the parent to relayout our views.
            switch (splitDirection) {
            case .horizontal:
                node = .horizontal(container)
            case .vertical:
                node = .vertical(container)
            }

            // See moveFocus comment, we have to run this whenever split changes.
            Ghostty.moveFocus(to: container.bottomRight.preferredFocus(), from: node!.preferredFocus())
        }

        /// This handles the event to move the split focus (i.e. previous/next) from a keyboard event.
        private func onMoveFocus(notification: SwiftUI.Notification) {
            // Determine our desired direction
            guard let directionAny = notification.userInfo?[Notification.SplitDirectionKey] else { return }
            guard let direction = directionAny as? SplitFocusDirection else { return }
            guard let next = neighbors.get(direction: direction) else { return }
            Ghostty.moveFocus(
                to: next.preferredFocus(direction)
            )
        }
    }
    
    /// This represents a split view that is in the horizontal or vertical split state.
    private struct TerminalSplitContainer2: View {
        let direction: SplitViewDirection
        let neighbors: SplitNode.Neighbors
        @Binding var node: SplitNode?
        @StateObject var container: SplitNode.Container

        var body: some View {
            SplitView(direction, left: {
                let neighborKey: WritableKeyPath<SplitNode.Neighbors, SplitNode?> = direction == .horizontal ? \.right : \.bottom

                TerminalSplitNested2(
                    node: closeableTopLeft(),
                    neighbors: neighbors.update([
                        neighborKey: container.bottomRight,
                        \.next: container.bottomRight,
                    ])
                )
            }, right: {
                let neighborKey: WritableKeyPath<SplitNode.Neighbors, SplitNode?> = direction == .horizontal ? \.left : \.top
                
                TerminalSplitNested2(
                    node: closeableBottomRight(),
                    neighbors: neighbors.update([
                        neighborKey: container.topLeft,
                        \.previous: container.topLeft,
                    ])
                )
            })
        }
        
        private func closeableTopLeft() -> Binding<SplitNode?> {
            return .init(get: {
                container.topLeft
            }, set: { newValue in
                if let newValue {
                    container.topLeft = newValue
                    return
                }
                
                // Closing
                container.topLeft.close()
                node = container.bottomRight
                
                Ghostty.moveFocus(to: node!.preferredFocus(), from: container.topLeft.preferredFocus())
            })
        }
        
        private func closeableBottomRight() -> Binding<SplitNode?> {
            return .init(get: {
                container.bottomRight
            }, set: { newValue in
                if let newValue {
                    container.bottomRight = newValue
                    return
                }
                
                // Closing
                container.bottomRight.close()
                node = container.topLeft
                
                Ghostty.moveFocus(to: node!.preferredFocus(), from: container.bottomRight.preferredFocus())
            })
        }
    }

    
    /// This is like TerminalSplitRoot, but... not the root. This renders a SplitNode in any state but
    /// requires there be a binding to the parent node.
    private struct TerminalSplitNested2: View {
        @Binding var node: SplitNode?
        let neighbors: SplitNode.Neighbors

        var body: some View {
            switch (node) {
            case nil:
                Color(.clear)
                
            case .noSplit(let leaf):
                TerminalSplitLeaf2(
                    leaf: leaf,
                    neighbors: neighbors,
                    node: $node
                )

            case .horizontal(let container):
                TerminalSplitContainer2(
                    direction: .horizontal,
                    neighbors: neighbors,
                    node: $node,
                    container: container
                )

            case .vertical(let container):
                TerminalSplitContainer2(
                    direction: .vertical,
                    neighbors: neighbors,
                    node: $node,
                    container: container
                )
            }
        }
    }
}
