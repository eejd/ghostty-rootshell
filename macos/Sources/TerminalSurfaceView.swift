import OSLog
import SwiftUI
import GhosttyKit

/// A surface is terminology in Ghostty for a terminal surface, or a place where a terminal is actually drawn
/// and interacted with. The word "surface" is used because a surface may represent a window, a tab,
/// a split, a small preview pane, etc. It is ANYTHING that has a terminal drawn to it.
///
/// We just wrap an AppKit NSView here at the moment so that we can behave as low level as possible
/// since that is what the Metal renderer in Ghostty expects. In the future, it may make more sense to
/// wrap an MTKView and use that, but for legacy reasons we didn't do that to begin with.
struct TerminalSurfaceView: NSViewRepresentable {
    var hasFocus: Bool
    @StateObject private var state: TerminalSurfaceView_Real
    
    init(app: ghostty_app_t, hasFocus: Bool) {
        self._state = StateObject(wrappedValue: TerminalSurfaceView_Real(app))
        self.hasFocus = hasFocus
    }
    
    func makeNSView(context: Context) -> TerminalSurfaceView_Real {
        // We need the view as part of the state to be created previously because
        // the view is sent to the Ghostty API so that it can manipulate it
        // directly since we draw on a render thread.
        return state;
    }
    
    func updateNSView(_ view: TerminalSurfaceView_Real, context: Context) {
        state.focusDidChange(hasFocus)
    }
}

// The actual NSView implementation for the terminal surface.
class TerminalSurfaceView_Real: NSView, NSTextInputClient, ObservableObject {
    // We need to support being a first responder so that we can get input events
    override var acceptsFirstResponder: Bool { return true }
    
    // I don't thikn we need this but this lets us know we should redraw our layer
    // so we'll use that to tell ghostty to refresh.
    override var wantsUpdateLayer: Bool { return true }
    
    // TODO: Figure out how to hook this up...
    @Published var title: String = "";
    
    private var surface: ghostty_surface_t? = nil
    private var error: Error? = nil
    private var markedText: NSMutableAttributedString;
    
    // Mapping of event keyCode to ghostty input key values. This is cribbed from
    // glfw mostly since we started as a glfw-based app way back in the day!
    static let keycodes: [UInt16 : ghostty_input_key_e] = [
        0x1D: GHOSTTY_KEY_ZERO,
        0x12: GHOSTTY_KEY_ONE,
        0x13: GHOSTTY_KEY_TWO,
        0x14: GHOSTTY_KEY_THREE,
        0x15: GHOSTTY_KEY_FOUR,
        0x17: GHOSTTY_KEY_FIVE,
        0x16: GHOSTTY_KEY_SIX,
        0x1A: GHOSTTY_KEY_SEVEN,
        0x1C: GHOSTTY_KEY_EIGHT,
        0x19: GHOSTTY_KEY_NINE,
        0x00: GHOSTTY_KEY_A,
        0x0B: GHOSTTY_KEY_B,
        0x08: GHOSTTY_KEY_C,
        0x02: GHOSTTY_KEY_D,
        0x0E: GHOSTTY_KEY_E,
        0x03: GHOSTTY_KEY_F,
        0x05: GHOSTTY_KEY_G,
        0x04: GHOSTTY_KEY_H,
        0x22: GHOSTTY_KEY_I,
        0x26: GHOSTTY_KEY_J,
        0x28: GHOSTTY_KEY_K,
        0x25: GHOSTTY_KEY_L,
        0x2E: GHOSTTY_KEY_M,
        0x2D: GHOSTTY_KEY_N,
        0x1F: GHOSTTY_KEY_O,
        0x23: GHOSTTY_KEY_P,
        0x0C: GHOSTTY_KEY_Q,
        0x0F: GHOSTTY_KEY_R,
        0x01: GHOSTTY_KEY_S,
        0x11: GHOSTTY_KEY_T,
        0x20: GHOSTTY_KEY_U,
        0x09: GHOSTTY_KEY_V,
        0x0D: GHOSTTY_KEY_W,
        0x07: GHOSTTY_KEY_X,
        0x10: GHOSTTY_KEY_Y,
        0x06: GHOSTTY_KEY_Z,

        0x27: GHOSTTY_KEY_APOSTROPHE,
        0x2A: GHOSTTY_KEY_BACKSLASH,
        0x2B: GHOSTTY_KEY_COMMA,
        0x18: GHOSTTY_KEY_EQUAL,
        0x32: GHOSTTY_KEY_GRAVE_ACCENT,
        0x21: GHOSTTY_KEY_LEFT_BRACKET,
        0x1B: GHOSTTY_KEY_MINUS,
        0x2F: GHOSTTY_KEY_PERIOD,
        0x1E: GHOSTTY_KEY_RIGHT_BRACKET,
        0x29: GHOSTTY_KEY_SEMICOLON,
        0x2C: GHOSTTY_KEY_SLASH,

        0x33: GHOSTTY_KEY_BACKSPACE,
        0x39: GHOSTTY_KEY_CAPS_LOCK,
        0x75: GHOSTTY_KEY_DELETE,
        0x7D: GHOSTTY_KEY_DOWN,
        0x77: GHOSTTY_KEY_END,
        0x24: GHOSTTY_KEY_ENTER,
        0x35: GHOSTTY_KEY_ESCAPE,
        0x7A: GHOSTTY_KEY_F1,
        0x78: GHOSTTY_KEY_F2,
        0x63: GHOSTTY_KEY_F3,
        0x76: GHOSTTY_KEY_F4,
        0x60: GHOSTTY_KEY_F5,
        0x61: GHOSTTY_KEY_F6,
        0x62: GHOSTTY_KEY_F7,
        0x64: GHOSTTY_KEY_F8,
        0x65: GHOSTTY_KEY_F9,
        0x6D: GHOSTTY_KEY_F10,
        0x67: GHOSTTY_KEY_F11,
        0x6F: GHOSTTY_KEY_F12,
        0x69: GHOSTTY_KEY_PRINT_SCREEN,
        0x6B: GHOSTTY_KEY_F14,
        0x71: GHOSTTY_KEY_F15,
        0x6A: GHOSTTY_KEY_F16,
        0x40: GHOSTTY_KEY_F17,
        0x4F: GHOSTTY_KEY_F18,
        0x50: GHOSTTY_KEY_F19,
        0x5A: GHOSTTY_KEY_F20,
        0x73: GHOSTTY_KEY_HOME,
        0x72: GHOSTTY_KEY_INSERT,
        0x7B: GHOSTTY_KEY_LEFT,
        0x3A: GHOSTTY_KEY_LEFT_ALT,
        0x3B: GHOSTTY_KEY_LEFT_CONTROL,
        0x38: GHOSTTY_KEY_LEFT_SHIFT,
        0x37: GHOSTTY_KEY_LEFT_SUPER,
        0x47: GHOSTTY_KEY_NUM_LOCK,
        0x79: GHOSTTY_KEY_PAGE_DOWN,
        0x74: GHOSTTY_KEY_PAGE_UP,
        0x7C: GHOSTTY_KEY_RIGHT,
        0x3D: GHOSTTY_KEY_RIGHT_ALT,
        0x3E: GHOSTTY_KEY_RIGHT_CONTROL,
        0x3C: GHOSTTY_KEY_RIGHT_SHIFT,
        0x36: GHOSTTY_KEY_RIGHT_SUPER,
        0x31: GHOSTTY_KEY_SPACE,
        0x30: GHOSTTY_KEY_TAB,
        0x7E: GHOSTTY_KEY_UP,

        0x52: GHOSTTY_KEY_KP_0,
        0x53: GHOSTTY_KEY_KP_1,
        0x54: GHOSTTY_KEY_KP_2,
        0x55: GHOSTTY_KEY_KP_3,
        0x56: GHOSTTY_KEY_KP_4,
        0x57: GHOSTTY_KEY_KP_5,
        0x58: GHOSTTY_KEY_KP_6,
        0x59: GHOSTTY_KEY_KP_7,
        0x5B: GHOSTTY_KEY_KP_8,
        0x5C: GHOSTTY_KEY_KP_9,
        0x45: GHOSTTY_KEY_KP_ADD,
        0x41: GHOSTTY_KEY_KP_DECIMAL,
        0x4B: GHOSTTY_KEY_KP_DIVIDE,
        0x4C: GHOSTTY_KEY_KP_ENTER,
        0x51: GHOSTTY_KEY_KP_EQUAL,
        0x43: GHOSTTY_KEY_KP_MULTIPLY,
        0x4E: GHOSTTY_KEY_KP_SUBTRACT,
    ];
    
    init(_ app: ghostty_app_t) {
        self.markedText = NSMutableAttributedString()
        
        // Initialize with some default frame size. The important thing is that this
        // is non-zero so that our layer bounds are non-zero so that our renderer
        // can do SOMETHING.
        super.init(frame: NSMakeRect(0, 0, 800, 600))
        
        // Setup our surface. This will also initialize all the terminal IO.
        var surface_cfg = ghostty_surface_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            nsview: Unmanaged.passUnretained(self).toOpaque(),
            scale_factor: NSScreen.main!.backingScaleFactor)
        guard let surface = ghostty_surface_new(app, &surface_cfg) else {
            self.error = AppError.surfaceCreateError
            return
        }
        
        self.surface = surface;
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }
    
    deinit {
        guard let surface = self.surface else { return }
        ghostty_surface_free(surface)
    }
    
    func focusDidChange(_ focused: Bool) {
        guard let surface = self.surface else { return }
        ghostty_surface_set_focus(surface, focused ? 1 : 0)
    }
    
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        
        if let surface = self.surface {
            // Ghostty wants to know the actual framebuffer size...
            let fbFrame = self.convertToBacking(self.frame);
            ghostty_surface_set_size(surface, UInt32(fbFrame.size.width), UInt32(fbFrame.size.height))
        }
    }
    
    override func viewDidChangeBackingProperties() {
        guard let surface = self.surface else { return }

        // Detect our X/Y scale factor so we can update our surface
        let fbFrame = self.convertToBacking(self.frame)
        let xScale = fbFrame.size.width / self.frame.size.width
        let yScale = fbFrame.size.height / self.frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        
        // When our scale factor changes, so does our fb size so we send that too
        ghostty_surface_set_size(surface, UInt32(fbFrame.size.width), UInt32(fbFrame.size.height))
    }
    
    override func updateLayer() {
        guard let surface = self.surface else { return }
        ghostty_surface_refresh(surface);
    }
    
    override func mouseDown(with event: NSEvent) {
        print("Mouse down: \(event)")
    }
    
    override func keyDown(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let key = Self.keycodes[event.keyCode] ?? GHOSTTY_KEY_INVALID
        let mods = Self.translateFlags(event.modifierFlags)
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        ghostty_surface_key(surface, action, key, mods)
        
        self.interpretKeyEvents([event])
    }
    
    override func keyUp(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let key = Self.keycodes[event.keyCode] ?? GHOSTTY_KEY_INVALID
        let mods = Self.translateFlags(event.modifierFlags)
        ghostty_surface_key(surface, GHOSTTY_ACTION_RELEASE, key, mods)
    }
    
    // MARK: NSTextInputClient
    
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }
    
    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length-1))
    }
    
    func selectedRange() -> NSRange {
        return NSRange()
    }
    
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: v)
            
        case let v as String:
            self.markedText = NSMutableAttributedString(string: v)
            
        default:
            print("unknown marked text: \(string)")
        }
    }
    
    func unmarkText() {
        self.markedText.mutableString.setString("")
    }
    
    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }
    
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }
    
    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }
    
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return NSMakeRect(frame.origin.x, frame.origin.y, 0, 0)
    }
    
    func insertText(_ string: Any, replacementRange: NSRange) {
        // We must have an associated event
        guard NSApp.currentEvent != nil else { return }
        guard let surface = self.surface else { return }
        
        // We want the string view of the any value
        var chars = ""
        switch (string) {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }
        
        for codepoint in chars.unicodeScalars {
            ghostty_surface_char(surface, codepoint.value)
        }
    }
    
    override func doCommand(by selector: Selector) {
        // This currently just prevents NSBeep from interpretKeyEvents but in the future
        // we may want to make some of this work.
        
        print("SEL: \(selector)")
    }
    
    private static func translateFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if (flags.contains(.shift)) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if (flags.contains(.control)) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if (flags.contains(.option)) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if (flags.contains(.command)) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if (flags.contains(.capsLock)) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        
        return ghostty_input_mods_e(mods)
    }
}

/*
 struct TerminalSurfaceView_Previews: PreviewProvider {
     static var previews: some View {
         TerminalSurfaceView()
     }
 }
 */
