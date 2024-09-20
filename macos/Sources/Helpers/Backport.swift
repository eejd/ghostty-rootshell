import SwiftUI

// All backport view/scene modifiers go as an extension on this. We use this
// so we can easily track and centralize all backports.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Scene {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Backport where Content: Scene {
    func defaultSize(width: CGFloat, height: CGFloat) -> some Scene {
        if #available(macOS 13, *) {
            return content.defaultSize(width: width, height: height)
        } else {
            return content
        }
    }
}

extension Backport where Content: View {
    func pointerStyle(_ style: BackportPointerStyle) -> some View {
        if #available(macOS 15, *) {
            return content.pointerStyle(style.official)
        } else {
            return content
        }
    }

    enum BackportPointerStyle {
        case grabIdle
        case grabActive
        case link

        @available(macOS 15, *)
        var official: PointerStyle {
            switch self {
            case .grabIdle: return .grabIdle
            case .grabActive: return .grabActive
            case .link: return .link
            }
        }
    }
}
