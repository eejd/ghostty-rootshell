import SwiftUI

struct TerminalSplitTreeView: View {
    let tree: SplitTree
    let onResize: (SplitTree.Node, Double) -> Void

    var body: some View {
        if let node = tree.root {
            TerminalSplitSubtreeView(node: node, isRoot: true, onResize: onResize)
        }
    }
}

struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree.Node
    var isRoot: Bool = false
    let onResize: (SplitTree.Node, Double) -> Void

    var body: some View {
        switch (node) {
        case .leaf(let leafView):
            // TODO: Fix the as!
            Ghostty.InspectableSurface(
                surfaceView: leafView as! Ghostty.SurfaceView,
                isSplit: !isRoot)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch (split.direction) {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    onResize(node, $0)
                }),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                resizePublisher: .init(),
                left: {
                    TerminalSplitSubtreeView(node: split.left, onResize: onResize)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, onResize: onResize)
                }
            )
        }
    }
}
