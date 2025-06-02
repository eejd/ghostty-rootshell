import SwiftUI

struct TerminalSplitTreeView: View {
    let tree: SplitTree

    var body: some View {
        if let node = tree.root {
            TerminalSplitSubtreeView(node: node, isRoot: true)
        }
    }
}

struct TerminalSplitSubtreeView: View {
    let node: SplitTree.Node
    var isRoot: Bool = false

    var body: some View {
        switch (node) {
        case .leaf(let leafView):
            // TODO: Fix the as!
            Ghostty.InspectableSurface(
                surfaceView: leafView as! Ghostty.SurfaceView,
                isSplit: !isRoot)

        case .split(let split):
            TerminalSplitSplitView(split: split)
        }
    }
}

struct TerminalSplitSplitView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let split: SplitTree.Node.Split

    private var splitViewDirection: SplitViewDirection {
        switch (split.direction) {
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
    }

    var body: some View {
        SplitView(
            splitViewDirection,
            .init(get: {
                CGFloat(split.ratio)
            }, set: { _ in
                // TODO
            }),
            dividerColor: ghostty.config.splitDividerColor,
            resizeIncrements: .init(width: 1, height: 1),
            resizePublisher: .init(),
            left: {
                TerminalSplitSubtreeView(node: split.left)
            },
            right: {
                TerminalSplitSubtreeView(node: split.right)
            }
        )
    }
}
