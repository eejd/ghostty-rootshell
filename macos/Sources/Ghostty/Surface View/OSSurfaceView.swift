import Foundation
import GhosttyKit

extension Ghostty {
    class OSSurfaceView: OSView, ObservableObject {
        typealias ID = UUID

        /// Unique ID per surface
        let id: UUID

        init(id: UUID?, frame: CGRect) {
            self.id = id ?? UUID()
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }
    }
}

