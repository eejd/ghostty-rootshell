import SwiftUI

extension KeyboardShortcut: @retroactive CustomStringConvertible {
    public var description: String {
        var result = ""

        if modifiers.contains(.command) {
            result.append("⌘")
        }
        if modifiers.contains(.control) {
            result.append("⌃")
        }
        if modifiers.contains(.option) {
            result.append("⌥")
        }
        if modifiers.contains(.shift) {
            result.append("⇧")
        }

        let keyString: String
        switch key {
        case .return: keyString = "⏎"
        case .escape: keyString = "⎋"
        case .delete: keyString = "⌫"
        case .space: keyString = "␣"
        case .tab: keyString = "⇥"
        case .upArrow: keyString = "↑"
        case .downArrow: keyString = "↓"
        case .leftArrow: keyString = "←"
        case .rightArrow: keyString = "→"
        case .pageUp: keyString = "PgUp"
        case .pageDown: keyString = "PgDown"
        case .end: keyString = "End"
        case .home: keyString = "Home"
        default:
            keyString = String(key.character.uppercased())
        }

        result.append(keyString)
        return result
    }
}

// This is available in macOS 14 so this only applies to early macOS versions.
extension KeyEquivalent: @retroactive Equatable {
    public static func == (lhs: KeyEquivalent, rhs: KeyEquivalent) -> Bool {
        lhs.character == rhs.character
    }
}
