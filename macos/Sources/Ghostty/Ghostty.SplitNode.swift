import SwiftUI
import GhosttyKit

extension Ghostty {
    /// This enum represents the possible states that a node in the split tree can be in. It is either:
    ///
    ///   - noSplit - This is an unsplit, single pane. This contains only a "leaf" which has a single
    ///   terminal surface to render.
    ///   - horizontal/vertical - This is split into the horizontal or vertical direction. This contains a
    ///   "container" which has a recursive top/left SplitNode and bottom/right SplitNode. These
    ///   values can further be split infinitely.
    ///
    enum SplitNode: Equatable, Hashable {
        case noSplit(Leaf)
        case horizontal(Container)
        case vertical(Container)
        
        /// Returns the view that would prefer receiving focus in this tree. This is always the
        /// top-left-most view. This is used when creating a split or closing a split to find the
        /// next view to send focus to.
        func preferredFocus(_ direction: SplitFocusDirection = .top) -> SurfaceView {
            let container: Container
            switch (self) {
            case .noSplit(let leaf):
                // noSplit is easy because there is only one thing to focus
                return leaf.surface

            case .horizontal(let c):
                container = c

            case .vertical(let c):
                container = c
            }
            
            let node: SplitNode
            switch (direction) {
            case .previous, .bottom, .left:
                node = container.bottomRight
                
            case .next, .top, .right:
                node = container.topLeft
            }
            
            return node.preferredFocus(direction)
        }

        /// Close the surface associated with this node. This will likely deinitialize the
        /// surface. At this point, the surface view in this node tree can never be used again.
        func close() {
            switch (self) {
            case .noSplit(let leaf):
                leaf.surface.close()

            case .horizontal(let container):
                container.topLeft.close()
                container.bottomRight.close()

            case .vertical(let container):
                container.topLeft.close()
                container.bottomRight.close()
            }
        }
        
        /// Returns true if any surface in the split stack requires quit confirmation.
        func needsConfirmQuit() -> Bool {
            switch (self) {
            case .noSplit(let leaf):
                return leaf.surface.needsConfirmQuit

            case .horizontal(let container):
                return container.topLeft.needsConfirmQuit() ||
                    container.bottomRight.needsConfirmQuit()

            case .vertical(let container):
                return container.topLeft.needsConfirmQuit() ||
                    container.bottomRight.needsConfirmQuit()
            }
        }

        /// Returns true if the split tree contains the given view.
        func contains(view: SurfaceView) -> Bool {
            switch (self) {
            case .noSplit(let leaf):
                return leaf.surface == view

            case .horizontal(let container):
                return container.topLeft.contains(view: view) ||
                    container.bottomRight.contains(view: view)

            case .vertical(let container):
                return container.topLeft.contains(view: view) ||
                    container.bottomRight.contains(view: view)
            }
        }
        
        // MARK: - Equatable
        
        static func == (lhs: SplitNode, rhs: SplitNode) -> Bool {
            switch (lhs, rhs) {
            case (.noSplit(let lhs_v), .noSplit(let rhs_v)):
                return lhs_v === rhs_v
            case (.horizontal(let lhs_v), .horizontal(let rhs_v)):
                return lhs_v === rhs_v
            case (.vertical(let lhs_v), .vertical(let rhs_v)):
                return lhs_v === rhs_v
            default:
                return false
            }
        }

        class Leaf: ObservableObject, Equatable, Hashable {
            let app: ghostty_app_t
            @Published var surface: SurfaceView

            /// Initialize a new leaf which creates a new terminal surface.
            init(_ app: ghostty_app_t, _ baseConfig: SurfaceConfiguration?) {
                self.app = app
                self.surface = SurfaceView(app, baseConfig)
            }
            
            // MARK: - Hashable
            
            func hash(into hasher: inout Hasher) {
                hasher.combine(app)
                hasher.combine(surface)
            }
            
            // MARK: - Equatable
            
            static func == (lhs: Leaf, rhs: Leaf) -> Bool {
                return lhs.app == rhs.app && lhs.surface === rhs.surface
            }
        }

        class Container: ObservableObject, Equatable, Hashable {
            let app: ghostty_app_t
            @Published var topLeft: SplitNode
            @Published var bottomRight: SplitNode

            /// A container is always initialized from some prior leaf because a split has to originate
            /// from a non-split value. When initializing, we inherit the leaf's surface and then
            /// initialize a new surface for the new pane.
            init(from: Leaf, baseConfig: SurfaceConfiguration? = nil) {
                self.app = from.app

                // Initially, both topLeft and bottomRight are in the "nosplit"
                // state since this is a new split.
                self.topLeft = .noSplit(from)
                self.bottomRight = .noSplit(.init(app, baseConfig))
            }
            
            // MARK: - Hashable
            
            func hash(into hasher: inout Hasher) {
                hasher.combine(app)
                hasher.combine(topLeft)
                hasher.combine(bottomRight)
            }
            
            // MARK: - Equatable
            
            static func == (lhs: Container, rhs: Container) -> Bool {
                return lhs.app == rhs.app &&
                    lhs.topLeft == rhs.topLeft &&
                    lhs.bottomRight == rhs.bottomRight
            }
        }

        /// This keeps track of the "neighbors" of a split: the immediately above/below/left/right
        /// nodes. This is purposely weak so we don't have to worry about memory management
        /// with this (although, it should always be correct).
        struct Neighbors {
            var left: SplitNode?
            var right: SplitNode?
            var top: SplitNode?
            var bottom: SplitNode?

            /// These are the previous/next nodes. It will certainly be one of the above as well
            /// but we keep track of these separately because depending on the split direction
            /// of the containing node, previous may be left OR top (same for next).
            var previous: SplitNode?
            var next: SplitNode?

            /// No neighbors, used by the root node.
            static let empty: Self = .init()

            /// Get the node for a given direction.
            func get(direction: SplitFocusDirection) -> SplitNode? {
                let map: [SplitFocusDirection : KeyPath<Self, SplitNode?>] = [
                    .previous: \.previous,
                    .next: \.next,
                    .top: \.top,
                    .bottom: \.bottom,
                    .left: \.left,
                    .right: \.right,
                ]

                guard let path = map[direction] else { return nil }
                return self[keyPath: path]
            }

            /// Update multiple keys and return a new copy.
            func update(_ attrs: [WritableKeyPath<Self, SplitNode?>: SplitNode?]) -> Self {
                var clone = self
                attrs.forEach { (key, value) in
                    clone[keyPath: key] = value
                }
                return clone
            }
            
            /// True if there are no neighbors
            func isEmpty() -> Bool {
                return self.previous == nil && self.next == nil
            }
        }
    }
}
