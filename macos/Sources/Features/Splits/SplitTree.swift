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

    /// Spatial representation of the split tree. This can be used to better understand
    /// its physical representation to perform tasks such as navigation.
    struct Spatial {
        let slots: [Slot]

        /// A single slot within the spatial mapping of a tree. Note that the bounds are
        /// _relative_. They can't be mapped to physical pixels because the SplitTree
        /// isn't aware of actual rendering. But relative to each other the bounds are
        /// correct.
        struct Slot {
            let node: Node
            let bounds: CGRect
        }
        
        /// Direction for spatial navigation within the split tree.
        enum Direction {
            case left
            case right
            case up
            case down
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

        // Spatially-aware navigation targets. These take into account the
        // layout to find the spatially correct node to move to. Spatial navigation
        // is always from the top-left corner for now.
        case spatial(Spatial.Direction)
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

        case .spatial(let spatialDirection):
            // Get spatial representation and find best candidate
            let spatial = root.spatial()
            let nodes = spatial.slots(in: spatialDirection, from: currentNode)

            // If we have no nodes in the direction specified then we don't do
            // anything.
            if nodes.isEmpty {
                return nil
            }

            // Extract the view from the best candidate node
            let bestNode = nodes[0].node
            switch bestNode {
            case .leaf(let view):
                return view
            case .split:
                // If the best candidate is a split node, use its the leaf/rightmost
                // depending on our spatial direction.
                return switch (spatialDirection) {
                case .up, .left: bestNode.leftmostLeaf()
                case .down, .right: bestNode.rightmostLeaf()
                }
            }
        }
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

    /// Calculate the bounds of all views in this subtree based on split ratios
    func calculateViewBounds(in bounds: CGRect) -> [(view: ViewType, bounds: CGRect)] {
        switch self {
        case .leaf(let view):
            return [(view, bounds)]
            
        case .split(let split):
            // Calculate bounds for left and right based on split direction and ratio
            let leftBounds: CGRect
            let rightBounds: CGRect
            
            switch split.direction {
            case .horizontal:
                // Split horizontally: left | right
                let splitX = bounds.minX + bounds.width * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width * split.ratio,
                    height: bounds.height
                )
                rightBounds = CGRect(
                    x: splitX,
                    y: bounds.minY,
                    width: bounds.width * (1 - split.ratio),
                    height: bounds.height
                )
                
            case .vertical:
                // Split vertically: top / bottom
                // Note: In our normalized coordinate system, Y increases upward
                let splitY = bounds.minY + bounds.height * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: splitY,
                    width: bounds.width,
                    height: bounds.height * (1 - split.ratio)
                )
                rightBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height * split.ratio
                )
            }
            
            // Recursively calculate bounds for children
            return split.left.calculateViewBounds(in: leftBounds) +
                   split.right.calculateViewBounds(in: rightBounds)
        }
    }
}

// MARK: SplitTree.Node Spatial

extension SplitTree.Node {
    /// Returns the spatial representation of this node and its subtree.
    ///
    /// This method creates a `Spatial` representation that maps the logical split tree structure
    /// to 2D coordinate space. The coordinate system uses (0,0) as the top-left corner with
    /// positive X extending right and positive Y extending down.
    ///
    /// The spatial representation provides:
    /// - Relative bounds for each node based on split ratios
    /// - Grid-like dimensions where each split adds 1 to the column/row count
    /// - Accurate positioning that reflects the actual layout structure
    ///
    /// The bounds are pixel perfect based on assuming that each row and column are 1 pixel
    /// tall or wide, respectively. This needs to be scaled up to the proper bounds for a real
    /// layout.
    ///
    /// Example:
    /// ```
    /// // For a layout like:
    /// // +--------+----+
    /// // |   A    | B  |
    /// // +--------+----+
    /// // |   C    | D  |
    /// // +--------+----+
    /// // 
    /// // The spatial representation would have:
    /// // - Total dimensions: (width: 2, height: 2)
    /// // - Node bounds based on actual split ratios
    /// ```
    ///
    /// - Returns: A `Spatial` struct containing all slots with their calculated bounds
    func spatial() -> SplitTree.Spatial {
        // First, calculate the total dimensions needed
        let dimensions = dimensions()

        // Calculate slots with relative bounds
        let slots = spatialSlots(
            in: CGRect(x: 0, y: 0, width: Double(dimensions.width), height: Double(dimensions.height))
        )

        return SplitTree.Spatial(slots: slots)
    }

    /// Calculates the grid dimensions (columns and rows) needed to represent this subtree.
    ///
    /// This method recursively analyzes the split tree structure to determine how many
    /// columns and rows are needed to represent the layout in a 2D grid. Each leaf node
    /// occupies one grid cell (1×1), and each split extends the grid in one direction:
    ///
    /// - **Horizontal splits**: Add columns (increase width)
    /// - **Vertical splits**: Add rows (increase height)
    ///
    /// The calculation rules are:
    /// - **Leaf nodes**: Always (1, 1) - one column, one row
    /// - **Horizontal splits**: Width = sum of children widths, Height = max of children heights
    /// - **Vertical splits**: Width = max of children widths, Height = sum of children heights
    ///
    /// Example:
    /// ```
    /// // Single leaf: (1, 1)
    /// // Horizontal split with 2 leaves: (2, 1)  
    /// // Vertical split with 2 leaves: (1, 2)
    /// // Complex layout with both: (2, 2) or larger
    /// ```
    ///
    /// - Returns: A tuple containing (width: columns, height: rows) as unsigned integers
    private func dimensions() -> (width: UInt, height: UInt) {
        switch self {
        case .leaf:
            return (1, 1)

        case .split(let split):
            let leftDimensions = split.left.dimensions()
            let rightDimensions = split.right.dimensions()

            switch split.direction {
            case .horizontal:
                // Horizontal split: width is sum, height is max
                return (
                    width: leftDimensions.width + rightDimensions.width,
                    height: Swift.max(leftDimensions.height, rightDimensions.height)
                )

            case .vertical:
                // Vertical split: height is sum, width is max
                return (
                    width: Swift.max(leftDimensions.width, rightDimensions.width),
                    height: leftDimensions.height + rightDimensions.height
                )
            }
        }
    }

    /// Calculates the spatial slots (nodes with bounds) for this subtree within the given bounds.
    ///
    /// This method recursively traverses the split tree and calculates the precise bounds
    /// for each node based on the split ratios and directions. The bounds are calculated
    /// relative to the provided bounds rectangle.
    ///
    /// The calculation process:
    /// 1. **Leaf nodes**: Create a single slot with the provided bounds
    /// 2. **Split nodes**: 
    ///    - Divide the bounds according to the split ratio and direction
    ///    - Create a slot for the split node itself
    ///    - Recursively calculate slots for both children
    ///    - Return all slots combined
    ///
    /// Split ratio interpretation:
    /// - **Horizontal splits**: Ratio determines left/right width distribution
    ///   - Left child gets `ratio * width`
    ///   - Right child gets `(1 - ratio) * width`
    /// - **Vertical splits**: Ratio determines top/bottom height distribution
    ///   - Top (left) child gets `ratio * height`
    ///   - Bottom (right) child gets `(1 - ratio) * height`
    ///
    /// Coordinate system: (0,0) is top-left, positive X goes right, positive Y goes down.
    ///
    /// - Parameter bounds: The bounding rectangle to subdivide for this subtree
    /// - Returns: An array of `Spatial.Slot` objects, each containing a node and its bounds
    private func spatialSlots(in bounds: CGRect) -> [SplitTree.Spatial.Slot] {
        switch self {
        case .leaf:
            // A leaf takes up our full bounds.
            return [.init(node: self, bounds: bounds)]

        case .split(let split):
            let leftBounds: CGRect
            let rightBounds: CGRect

            switch split.direction {
            case .horizontal:
                // Split horizontally: left | right using the ratio
                let splitX = bounds.minX + bounds.width * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width * split.ratio,
                    height: bounds.height
                )
                rightBounds = CGRect(
                    x: splitX,
                    y: bounds.minY,
                    width: bounds.width * (1 - split.ratio),
                    height: bounds.height
                )

            case .vertical:
                // Split vertically: top / bottom using the ratio
                // Top-left is (0,0), so top (left) gets the upper portion
                let splitY = bounds.minY + bounds.height * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height * split.ratio
                )
                rightBounds = CGRect(
                    x: bounds.minX,
                    y: splitY,
                    width: bounds.width,
                    height: bounds.height * (1 - split.ratio)
                )
            }

            // Recursively calculate slots for children and include a slot for this split
            var slots: [SplitTree.Spatial.Slot] = [.init(node: self, bounds: bounds)]
            slots += split.left.spatialSlots(in: leftBounds)
            slots += split.right.spatialSlots(in: rightBounds)

            return slots
        }
    }
}

// MARK: SplitTree.Spatial

extension SplitTree.Spatial {
    /// Returns all slots in the specified direction relative to the reference node.
    ///
    /// This method finds all slots positioned in the given direction from the reference node:
    /// - **Left**: Slots with bounds to the left of the reference node
    /// - **Right**: Slots with bounds to the right of the reference node  
    /// - **Up**: Slots with bounds above the reference node (Y=0 is top)
    /// - **Down**: Slots with bounds below the reference node
    ///
    /// Results are sorted by distance from the reference node, with closest slots first.
    /// Distance is calculated as the gap between the reference node and the candidate slot
    /// in the direction of movement.
    ///
    /// - Parameters:
    ///   - direction: The direction to search for slots
    ///   - referenceNode: The node to use as the reference point
    /// - Returns: An array of slots in the specified direction, sorted by distance (closest first)
    func slots(in direction: Direction, from referenceNode: SplitTree.Node) -> [Slot] {
        guard let refSlot = slots.first(where: { $0.node == referenceNode }) else { return [] }
        
        return switch direction {
        case .left:
            // Slots to the left: their right edge is at or left of reference's left edge
            slots.filter {
                $0.node != referenceNode && $0.bounds.maxX <= refSlot.bounds.minX 
            }.sorted {
                (refSlot.bounds.minX - $0.bounds.maxX) < (refSlot.bounds.minX - $1.bounds.maxX)
            }

        case .right:
            // Slots to the right: their left edge is at or right of reference's right edge
            slots.filter {
                $0.node != referenceNode && $0.bounds.minX >= refSlot.bounds.maxX 
            }.sorted {
                ($0.bounds.minX - refSlot.bounds.maxX) < ($1.bounds.minX - refSlot.bounds.maxX)
            }
            
        case .up:
            // Slots above: their bottom edge is at or above reference's top edge
            slots.filter {
                $0.node != referenceNode && $0.bounds.maxY <= refSlot.bounds.minY 
            }.sorted {
                (refSlot.bounds.minY - $0.bounds.maxY) < (refSlot.bounds.minY - $1.bounds.maxY)
            }
            
        case .down:
            // Slots below: their top edge is at or below reference's bottom edge
            slots.filter {
                $0.node != referenceNode && $0.bounds.minY >= refSlot.bounds.maxY 
            }.sorted {
                ($0.bounds.minY - refSlot.bounds.maxY) < ($1.bounds.minY - refSlot.bounds.maxY)
            }
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
