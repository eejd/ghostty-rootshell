import Foundation
import GhosttyKit

extension Ghostty {
    class OSSurfaceView: OSView, ObservableObject {
        typealias ID = UUID

        /// Unique ID per surface
        let id: UUID

        // The current pwd of the surface as defined by the pty. This can be
        // changed with escape codes.
        @Published var pwd: String?

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        @Published var cellSize: CGSize = .zero

        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        @Published var healthy: Bool = true

        // Any error while initializing the surface.
        @Published var error: Error?

        // The hovered URL string
        @Published var hoverUrl: String?

        // The progress report (if any)
        @Published var progressReport: Action.ProgressReport?

        init(id: UUID?, frame: CGRect) {
            self.id = id ?? UUID()
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }
    }
}

