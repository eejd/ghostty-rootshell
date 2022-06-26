/// C0 (7-bit) control characters from ANSI.
///
/// This is not complete, control characters are only added to this
/// as the terminal emulator handles them.
pub const C0 = enum(u7) {
    /// Null
    NUL = 0x00,
    /// Enquiry
    ENQ = 0x05,
    /// Bell
    BEL = 0x07,
    /// Backspace
    BS = 0x08,
    // Horizontal tab
    HT = 0x09,
    /// Line feed
    LF = 0x0A,
    /// Vertical Tab
    VT = 0x0B,
    /// Carriage return
    CR = 0x0D,
    /// Shift out
    SO = 0x0E,
    /// Shift in
    SI = 0x0F,
};

/// The SGR rendition aspects that can be set, sometimes known as attributes.
/// The value corresponds to the parameter value for the SGR command (ESC [ m).
pub const RenditionAspect = enum(u16) {
    default = 0,
    bold = 1,
    default_fg = 39,
    default_bg = 49,

    // Non-exhaustive so that @intToEnum never fails since the inputs are
    // user-generated.
    _,
};

/// Modes that can be set with with Set Mode (SM) (ESC [ h). The enum
/// values correspond to the `?`-prefixed modes, since those are the ones
/// of primary interest. The enum value is the mode value.
pub const Mode = enum(u16) {
    /// Reverses the foreground and background colors of all cells.
    reverse_colors = 5,

    /// If set, the origin of the coordinate system is relative to the
    /// current scroll region. If set the cursor is moved to the top left of
    /// the current scroll region.
    origin = 6,

    /// Bracket clipboard paste contents in delimiter sequences.
    ///
    /// When pasting from the (e.g. system) clipboard add "ESC [ 2 0 0 ~"
    /// before the clipboard contents and "ESC [ 2 0 1 ~" after the clipboard
    /// contents. This allows applications to distinguish clipboard contents
    /// from manually typed text.
    bracketed_paste = 2004,

    // Non-exhaustive so that @intToEnum never fails for unsupported modes.
    _,
};

/// The device attribute request type (ESC [ c).
pub const DeviceAttributeReq = enum {
    primary, // Blank
    secondary, // >
    tertiary, // =
};

/// The device status request type (ESC [ n).
pub const DeviceStatusReq = enum(u16) {
    operating_status = 5,
    cursor_position = 6,

    // Non-exhaustive so that @intToEnum never fails for unsupported modes.
    _,
};

/// Possible cursor styles (ESC [ q)
pub const CursorStyle = enum(u16) {
    default = 0,
    blinking_block = 1,
    steady_block = 2,
    blinking_underline = 3,
    steady_underline = 4,
    blinking_bar = 5,
    steady_bar = 6,

    // Non-exhaustive so that @intToEnum never fails for unsupported modes.
    _,

    /// True if the cursor should blink.
    pub fn blinking(self: CursorStyle) bool {
        return switch (self) {
            .blinking_block, .blinking_underline, .blinking_bar => true,
            else => false,
        };
    }
};
