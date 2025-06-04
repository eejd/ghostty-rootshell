import AppKit

/// SplitTree represents a tree of views that can be divided.
struct SplitTree<ViewType: NSView & Codable>: Codable {
    /// The root of the tree. This can be nil to indicate the tree is empty.
    let root: Node?

    /// The node that is currently zoomed. A zoomed split is expected to take up the full
    /// size of the view area where the splits are shown.
    let zoomed: Node?

    /// A single node in the tree is either a leaf node (a view) or a split (has a
    /// left/right or top/bottom).
    indirect enum Node: Codable {
        case leaf(view: ViewType)
        case split(Split)

        struct Split: Equatable, Codable {
            let direction: Direction
            let ratio: Double
            let left: Node
            let right: Node
        }
    }

    enum Direction: Codable {
        case horizontal // Splits are laid out left and right
        case vertical // Splits are laid out top and bottom
    }

    /// The path to a specific node in the tree.
    struct Path {
        let path: [Component]

        var isEmpty: Bool { path.isEmpty }

        enum Component {
            case left
            case right
        }
    }

    enum SplitError: Error {
        case viewNotFound
    }

    enum NewDirection {
        case left
        case right
        case down
        case up
    }

    /// The direction that focus can move from a node.
    enum FocusDirection {
        // Follow a consistent tree-like structure.
        case previous
        case next

        // Geospatially-aware navigation targets. These take into account the
        // dimensions of the view to find the correct node to go to.
        case up
        case down
        case left
        case right
    }
}

// MARK: SplitTree

extension SplitTree {
    var isEmpty: Bool {
        root == nil
    }

    /// Returns true if this tree is split.
    var isSplit: Bool {
        if case .split = root { true } else { false }
    }

    init() {
        self.init(root: nil, zoomed: nil)
    }

    init(view: ViewType) {
        self.init(root: .leaf(view: view), zoomed: nil)
    }

    /// Insert a new view at the given view point by creating a split in the given direction.
    func insert(view: ViewType, at: ViewType, direction: NewDirection) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }
        return .init(
            root: try root.insert(view: view, at: at, direction: direction),
            zoomed: zoomed)
    }

    /// Remove a node from the tree. If the node being removed is part of a split,
    /// the sibling node takes the place of the parent split.
    func remove(_ target: Node) -> Self {
        guard let root else { return self }
        
        // If we're removing the root itself, return an empty tree
        if root == target {
            return .init(root: nil, zoomed: nil)
        }
        
        // Otherwise, try to remove from the tree
        let newRoot = root.remove(target)
        
        // Update zoomed if it was the removed node
        let newZoomed = (zoomed == target) ? nil : zoomed
        
        return .init(root: newRoot, zoomed: newZoomed)
    }

    /// Replace a node in the tree with a new node.
    func replace(node: Node, with newNode: Node) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }
        
        // Get the path to the node we want to replace
        guard let path = root.path(to: node) else {
            throw SplitError.viewNotFound
        }
        
        // Replace the node
        let newRoot = try root.replaceNode(at: path, with: newNode)
        
        // Update zoomed if it was the replaced node
        let newZoomed = (zoomed == node) ? newNode : zoomed
        
        return .init(root: newRoot, zoomed: newZoomed)
    }
    
    /// Find the next view to focus based on the current focused node and direction
    func focusTarget(for direction: FocusDirection, from currentNode: Node) -> ViewType? {
        guard let root else { return nil }
        
        switch direction {
        case .previous:
            // For previous, we traverse in order and find the previous leaf from our leftmost
            let allLeaves = root.leaves()
            let currentView = currentNode.leftmostLeaf()
            guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
                // Shouldn't be possible leftmostLeaf can't return something that doesn't exist!
                return nil
            }
            let index = allLeaves.indexWrapping(before: currentIndex)
            return allLeaves[index]

        case .next:
            // For previous, we traverse in order and find the next leaf from our rightmost
            let allLeaves = root.leaves()
            let currentView = currentNode.rightmostLeaf()
            guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
                return nil
            }
            let index = allLeaves.indexWrapping(after: currentIndex)
            return allLeaves[index]

        case .up, .down, .left, .right:
            // For directional movement, we need to traverse the tree structure
            return directionalTarget(for: direction, from: currentNode)
        }
    }
    
    /// Find focus target in a specific direction by traversing split boundaries
    private func directionalTarget(for direction: FocusDirection, from currentNode: Node) -> ViewType? {
        // TODO
        return nil
    }
    
    /// Equalize all splits in the tree so that each split's ratio is based on the
    /// relative weight (number of leaves) of its children.
    func equalize() -> Self {
        guard let root else { return self }
        let newRoot = root.equalize()
        return .init(root: newRoot, zoomed: zoomed)
    }
}

// MARK: SplitTree.Node

extension SplitTree.Node {
    typealias Node = SplitTree.Node
    typealias NewDirection = SplitTree.NewDirection
    typealias SplitError = SplitTree.SplitError
    typealias Path = SplitTree.Path

    /// Returns the node in the tree that contains the given view.
    func node(view: ViewType) -> Node? {
        switch (self) {
        case .leaf(view):
            return self

        case .split(let split):
            if let result = split.left.node(view: view) {
                return result
            } else if let result = split.right.node(view: view) {
                return result
            }

            return nil

        default:
            return nil
        }
    }

    /// Returns the path to a given node in the tree. If the returned value is nil then the
    /// node doesn't exist.
    func path(to node: Self) -> Path? {
        var components: [Path.Component] = []
        func search(_ current: Self) -> Bool {
            if current == node {
                return true
            }

            switch current {
            case .leaf:
                return false

            case .split(let split):
                // Try left branch
                components.append(.left)
                if search(split.left) {
                    return true
                }
                components.removeLast()

                // Try right branch
                components.append(.right)
                if search(split.right) {
                    return true
                }
                components.removeLast()

                return false
            }
        }

        return search(self) ? Path(path: components) : nil
    }

    /// Inserts a new view into the split tree by creating a split at the location of an existing view.
    ///
    /// This method creates a new split node containing both the existing view and the new view,
    /// The position of the new view relative to the existing view is determined by the direction parameter.
    ///
    /// - Parameters:
    ///   - view: The new view to insert into the tree
    ///   - at: The existing view at whose location the split should be created
    ///   - direction: The direction relative to the existing view where the new view should be placed
    ///
    /// - Note: If the existing view (`at`) is not found in the tree, this method does nothing. We should
    /// maybe throw instead but at the moment we just do nothing.
    func insert(view: ViewType, at: ViewType, direction: NewDirection) throws -> Self {
        // Get the path to our insertion point. If it doesn't exist we do
        // nothing.
        guard let path = path(to: .leaf(view: at)) else {
            throw SplitError.viewNotFound
        }

        // Determine split direction and which side the new view goes on
        let splitDirection: SplitTree.Direction
        let newViewOnLeft: Bool
        switch direction {
        case .left:
            splitDirection = .horizontal
            newViewOnLeft = true
        case .right:
            splitDirection = .horizontal
            newViewOnLeft = false
        case .up:
            splitDirection = .vertical
            newViewOnLeft = true
        case .down:
            splitDirection = .vertical
            newViewOnLeft = false
        }

        // Create the new split node
        let newNode: Node = .leaf(view: view)
        let existingNode: Node = .leaf(view: at)
        let newSplit: Node = .split(.init(
            direction: splitDirection,
            ratio: 0.5,
            left: newViewOnLeft ? newNode : existingNode,
            right: newViewOnLeft ? existingNode : newNode
        ))

        // Replace the node at the path with the new split
        return try replaceNode(at: path, with: newSplit)
    }

    /// Helper function to replace a node at the given path from the root
    func replaceNode(at path: Path, with newNode: Self) throws -> Self {
        // If path is empty, replace the root
        if path.isEmpty {
            return newNode
        }

        // Otherwise, we need to replace the proper left/right all along
        // the way since Node is a value type (enum). To do that, we need
        // recursion. We can't use a simple iterative approach because we
        // can't update in-place.
        func replaceInner(current: Node, pathOffset: Int) throws -> Node {
            // Base case: if we've consumed the entire path, replace this node
            if pathOffset >= path.path.count {
                return newNode
            }

            // We need to go deeper, so current must be a split for the path
            // to be valid. Otherwise, the path is invalid.
            guard case .split(let split) = current else {
                throw SplitError.viewNotFound
            }

            let component = path.path[pathOffset]
            switch component {
            case .left:
                return .split(.init(
                    direction: split.direction,
                    ratio: split.ratio,
                    left: try replaceInner(current: split.left, pathOffset: pathOffset + 1),
                    right: split.right
                ))
            case .right:
                return .split(.init(
                    direction: split.direction,
                    ratio: split.ratio,
                    left: split.left,
                    right: try replaceInner(current: split.right, pathOffset: pathOffset + 1)
                ))
            }
        }

        return try replaceInner(current: self, pathOffset: 0)
    }

    /// Remove a node from the tree. Returns the modified tree, or nil if removing
    /// the node results in an empty tree.
    func remove(_ target: Node) -> Node? {
        // If we're removing ourselves, return nil
        if self == target {
            return nil
        }
        
        switch self {
        case .leaf:
            // A leaf that isn't the target stays as is
            return self
            
        case .split(let split):
            // Neither child is directly the target, so we need to recursively
            // try to remove from both children
            let newLeft = split.left.remove(target)
            let newRight = split.right.remove(target)

            // If both are nil then we remove everything. This shouldn't ever
            // happen because duplicate nodes shouldn't exist, but we want to
            // be robust against it.
            if newLeft == nil && newRight == nil {
                return nil
            } else if newLeft == nil {
                return newRight
            } else if newRight == nil {
                return newLeft
            }
            
            // Both children still exist after removal
            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: newLeft!,
                right: newRight!
            ))
        }
    }

    /// Resize a split node to the specified ratio.
    /// For leaf nodes, this returns the node unchanged.
    /// For split nodes, this creates a new split with the updated ratio.
    func resize(to ratio: Double) -> Self {
        switch self {
        case .leaf:
            // Leaf nodes don't have a ratio to resize
            return self
            
        case .split(let split):
            // Create a new split with the updated ratio
            return .split(.init(
                direction: split.direction,
                ratio: ratio,
                left: split.left,
                right: split.right
            ))
        }
    }
    
    /// Get the leftmost leaf in this subtree
    func leftmostLeaf() -> ViewType {
        switch self {
        case .leaf(let view):
            return view
        case .split(let split):
            return split.left.leftmostLeaf()
        }
    }
    
    /// Get the rightmost leaf in this subtree
    func rightmostLeaf() -> ViewType {
        switch self {
        case .leaf(let view):
            return view
        case .split(let split):
            return split.right.rightmostLeaf()
        }
    }
    
    /// Equalize this node and all its children, returning a new node with splits
    /// adjusted so that each split's ratio is based on the relative weight
    /// (number of leaves) of its children.
    func equalize() -> Node {
        let (equalizedNode, _) = equalizeWithWeight()
        return equalizedNode
    }
    
    /// Internal helper that equalizes and returns both the node and its weight.
    private func equalizeWithWeight() -> (node: Node, weight: Int) {
        switch self {
        case .leaf:
            // A leaf has weight 1 and doesn't change
            return (self, 1)
            
        case .split(let split):
            // Recursively equalize children
            let (leftNode, leftWeight) = split.left.equalizeWithWeight()
            let (rightNode, rightWeight) = split.right.equalizeWithWeight()
            
            // Calculate new ratio based on relative weights
            let totalWeight = leftWeight + rightWeight
            let newRatio = Double(leftWeight) / Double(totalWeight)
            
            // Create new split with equalized ratio
            let newSplit = Split(
                direction: split.direction,
                ratio: newRatio,
                left: leftNode,
                right: rightNode
            )
            
            return (.split(newSplit), totalWeight)
        }
    }
}

// MARK: SplitTree.Node Protocols

extension SplitTree.Node: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.leaf(leftView), .leaf(rightView)):
            // Compare NSView instances by object identity
            return leftView === rightView

        case let (.split(split1), .split(split2)):
            return split1 == split2

        default:
            return false
        }
    }
}

// MARK: SplitTree Codable

extension SplitTree.Node {
    enum CodingKeys: String, CodingKey {
        case view
        case split
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if container.contains(.view) {
            let view = try container.decode(ViewType.self, forKey: .view)
            self = .leaf(view: view)
        } else if container.contains(.split) {
            let split = try container.decode(Split.self, forKey: .split)
            self = .split(split)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "No valid node type found"
                )
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .leaf(let view):
            try container.encode(view, forKey: .view)
            
        case .split(let split):
            try container.encode(split, forKey: .split)
        }
    }
}

// MARK: SplitTree Sequences

extension SplitTree.Node {
    /// Returns all leaf views in this subtree
    func leaves() -> [ViewType] {
        switch self {
        case .leaf(let view):
            return [view]
            
        case .split(let split):
            return split.left.leaves() + split.right.leaves()
        }
    }
}

extension SplitTree: Sequence {
    func makeIterator() -> [ViewType].Iterator {
        return root?.leaves().makeIterator() ?? [].makeIterator()
    }
}

extension SplitTree.Node: Sequence {
    func makeIterator() -> [ViewType].Iterator {
        return leaves().makeIterator()
    }
}
