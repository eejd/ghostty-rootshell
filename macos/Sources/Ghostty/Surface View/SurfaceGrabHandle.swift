import SwiftUI

extension Ghostty {
    /// A grab handle overlay at the top of the surface for dragging a surface.
    struct SurfaceGrabHandle: View {
        @ObservedObject var surfaceView: SurfaceView

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

        private var handleVisible: Bool {
            // Handle should always be visible in non-fullscreen
            guard let window = surfaceView.window else { return true }
            guard window.styleMask.contains(.fullScreen) else { return true }

            // If fullscreen, only show the handle if we have splits
            guard let controller = window.windowController as? BaseTerminalController else { return false }
            return controller.surfaceTree.isSplit
        }

        private var ellipsisVisible: Bool {
            surfaceView.mouseOverSurface && surfaceView.cursorVisible
        }

        var body: some View {
            if handleVisible {
                ZStack {
                    SurfaceDragSource(
                        surfaceView: surfaceView,
                        isDragging: $isDragging,
                        isHovering: $isHovering
                    )
                    .frame(width: 80, height: 12)
                    .contentShape(Rectangle())

                    if ellipsisVisible {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.primary.opacity(isHovering ? 0.8 : 0.3))
                            .offset(y: -3)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}
