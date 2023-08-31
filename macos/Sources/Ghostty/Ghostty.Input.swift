import Cocoa
import GhosttyKit

extension Ghostty {
    /// Returns the "keyEquivalent" string for a given input key. This doesn't always have a corresponding key.
    static func keyEquivalent(key: ghostty_input_key_e) -> String? {
        guard let byte = Self.keyToAscii[key] else { return nil }
        return String(bytes: [byte], encoding: .utf8)
    }
    
    /// Returns the event modifier flags set for the Ghostty mods enum.
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: [NSEvent.ModifierFlags] = [];
        if (mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0) { flags.append(.shift) }
        if (mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0) { flags.append(.control) }
        if (mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0) { flags.append(.option) }
        if (mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0) { flags.append(.command) }
        return NSEvent.ModifierFlags(flags)
    }
    
    static let keyToAscii: [ghostty_input_key_e : UInt8] = [
        // 0-9
        GHOSTTY_KEY_ZERO: 0x30,
        GHOSTTY_KEY_ONE: 0x31,
        GHOSTTY_KEY_TWO: 0x32,
        GHOSTTY_KEY_THREE: 0x33,
        GHOSTTY_KEY_FOUR: 0x34,
        GHOSTTY_KEY_FIVE: 0x35,
        GHOSTTY_KEY_SIX: 0x36,
        GHOSTTY_KEY_SEVEN: 0x37,
        GHOSTTY_KEY_EIGHT: 0x38,
        GHOSTTY_KEY_NINE: 0x39,

        // a-z
        GHOSTTY_KEY_A: 0x61,
        GHOSTTY_KEY_B: 0x62,
        GHOSTTY_KEY_C: 0x63,
        GHOSTTY_KEY_D: 0x64,
        GHOSTTY_KEY_E: 0x65,
        GHOSTTY_KEY_F: 0x66,
        GHOSTTY_KEY_G: 0x67,
        GHOSTTY_KEY_H: 0x68,
        GHOSTTY_KEY_I: 0x69,
        GHOSTTY_KEY_J: 0x6A,
        GHOSTTY_KEY_K: 0x6B,
        GHOSTTY_KEY_L: 0x6C,
        GHOSTTY_KEY_M: 0x6D,
        GHOSTTY_KEY_N: 0x6E,
        GHOSTTY_KEY_O: 0x6F,
        GHOSTTY_KEY_P: 0x70,
        GHOSTTY_KEY_Q: 0x71,
        GHOSTTY_KEY_R: 0x72,
        GHOSTTY_KEY_S: 0x73,
        GHOSTTY_KEY_T: 0x74,
        GHOSTTY_KEY_U: 0x75,
        GHOSTTY_KEY_V: 0x76,
        GHOSTTY_KEY_W: 0x77,
        GHOSTTY_KEY_X: 0x78,
        GHOSTTY_KEY_Y: 0x79,
        GHOSTTY_KEY_Z: 0x7A,

        // Symbols
        GHOSTTY_KEY_APOSTROPHE: 0x27,
        GHOSTTY_KEY_BACKSLASH: 0x5C,
        GHOSTTY_KEY_COMMA: 0x2C,
        GHOSTTY_KEY_EQUAL: 0x3D,
        GHOSTTY_KEY_GRAVE_ACCENT: 0x60,
        GHOSTTY_KEY_LEFT_BRACKET: 0x5B,
        GHOSTTY_KEY_MINUS: 0x2D,
        GHOSTTY_KEY_PERIOD: 0x2E,
        GHOSTTY_KEY_RIGHT_BRACKET: 0x5D,
        GHOSTTY_KEY_SEMICOLON: 0x3B,
        GHOSTTY_KEY_SLASH: 0x2F,
    ]
    
    static let asciiToKey: [UInt8 : ghostty_input_key_e] = [
        // 0-9
        0x30: GHOSTTY_KEY_ZERO,
        0x31: GHOSTTY_KEY_ONE,
        0x32: GHOSTTY_KEY_TWO,
        0x33: GHOSTTY_KEY_THREE,
        0x34: GHOSTTY_KEY_FOUR,
        0x35: GHOSTTY_KEY_FIVE,
        0x36: GHOSTTY_KEY_SIX,
        0x37: GHOSTTY_KEY_SEVEN,
        0x38: GHOSTTY_KEY_EIGHT,
        0x39: GHOSTTY_KEY_NINE,
        
        // A-Z
        0x41: GHOSTTY_KEY_A,
        0x42: GHOSTTY_KEY_B,
        0x43: GHOSTTY_KEY_C,
        0x44: GHOSTTY_KEY_D,
        0x45: GHOSTTY_KEY_E,
        0x46: GHOSTTY_KEY_F,
        0x47: GHOSTTY_KEY_G,
        0x48: GHOSTTY_KEY_H,
        0x49: GHOSTTY_KEY_I,
        0x4A: GHOSTTY_KEY_J,
        0x4B: GHOSTTY_KEY_K,
        0x4C: GHOSTTY_KEY_L,
        0x4D: GHOSTTY_KEY_M,
        0x4E: GHOSTTY_KEY_N,
        0x4F: GHOSTTY_KEY_O,
        0x50: GHOSTTY_KEY_P,
        0x51: GHOSTTY_KEY_Q,
        0x52: GHOSTTY_KEY_R,
        0x53: GHOSTTY_KEY_S,
        0x54: GHOSTTY_KEY_T,
        0x55: GHOSTTY_KEY_U,
        0x56: GHOSTTY_KEY_V,
        0x57: GHOSTTY_KEY_W,
        0x58: GHOSTTY_KEY_X,
        0x59: GHOSTTY_KEY_Y,
        0x5A: GHOSTTY_KEY_Z,
        
        // a-z
        0x61: GHOSTTY_KEY_A,
        0x62: GHOSTTY_KEY_B,
        0x63: GHOSTTY_KEY_C,
        0x64: GHOSTTY_KEY_D,
        0x65: GHOSTTY_KEY_E,
        0x66: GHOSTTY_KEY_F,
        0x67: GHOSTTY_KEY_G,
        0x68: GHOSTTY_KEY_H,
        0x69: GHOSTTY_KEY_I,
        0x6A: GHOSTTY_KEY_J,
        0x6B: GHOSTTY_KEY_K,
        0x6C: GHOSTTY_KEY_L,
        0x6D: GHOSTTY_KEY_M,
        0x6E: GHOSTTY_KEY_N,
        0x6F: GHOSTTY_KEY_O,
        0x70: GHOSTTY_KEY_P,
        0x71: GHOSTTY_KEY_Q,
        0x72: GHOSTTY_KEY_R,
        0x73: GHOSTTY_KEY_S,
        0x74: GHOSTTY_KEY_T,
        0x75: GHOSTTY_KEY_U,
        0x76: GHOSTTY_KEY_V,
        0x77: GHOSTTY_KEY_W,
        0x78: GHOSTTY_KEY_X,
        0x79: GHOSTTY_KEY_Y,
        0x7A: GHOSTTY_KEY_Z,
        
        // Symbols
        0x27: GHOSTTY_KEY_APOSTROPHE,
        0x5C: GHOSTTY_KEY_BACKSLASH,
        0x2C: GHOSTTY_KEY_COMMA,
        0x3D: GHOSTTY_KEY_EQUAL,
        0x60: GHOSTTY_KEY_GRAVE_ACCENT,
        0x5B: GHOSTTY_KEY_LEFT_BRACKET,
        0x2D: GHOSTTY_KEY_MINUS,
        0x2E: GHOSTTY_KEY_PERIOD,
        0x5D: GHOSTTY_KEY_RIGHT_BRACKET,
        0x3B: GHOSTTY_KEY_SEMICOLON,
        0x2F: GHOSTTY_KEY_SLASH,
    ]
}
