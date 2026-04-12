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

        init(id: UUID?, frame: CGRect) {
            self.id = id ?? UUID()
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }
    }
}

