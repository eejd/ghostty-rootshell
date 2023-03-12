import SwiftUI
import GhosttyKit

struct Ghostty {
    // All the notifications that will be emitted will be put here.
    struct Notification {}
}

// MARK: Surface Notifications

extension Ghostty {
    /// An enum that is used for the directions that a split focus event can change.
    enum SplitFocusDirection {
        case previous, next
        
        /// Initialize from a Ghostty API enum.
        static func from(direction: ghostty_split_focus_direction_e) -> Self? {
            switch (direction) {
            case GHOSTTY_SPLIT_FOCUS_PREVIOUS:
                return .previous
                
            case GHOSTTY_SPLIT_FOCUS_NEXT:
                return .next
                
            default:
                return nil
            }
        }
        
        func toNative() -> ghostty_split_focus_direction_e {
            switch (self) {
            case .previous:
                return GHOSTTY_SPLIT_FOCUS_PREVIOUS
                
            case .next:
                return GHOSTTY_SPLIT_FOCUS_NEXT
            }
        }
    }
}

extension Ghostty.Notification {
    /// Posted when a new split is requested. The sending object will be the surface that had focus. The
    /// userdata has one key "direction" with the direction to split to.
    static let ghosttyNewSplit = Notification.Name("com.mitchellh.ghostty.newSplit")
    
    /// Close the calling surface.
    static let ghosttyCloseSurface = Notification.Name("com.mitchellh.ghostty.closeSurface")
    
    /// Focus previous/next split. Has a SplitFocusDirection in the userinfo.
    static let ghosttyFocusSplit = Notification.Name("com.mitchellh.ghostty.focusSplit")
    static let SplitDirectionKey = ghosttyFocusSplit.rawValue
}
