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

    // Non-exhaustive so that @intToEnum never fails since the inputs are
    // user-generated.
    _,
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
    /// This control function selects the sequences the arrow keys send.
    /// You can use the four arrow keys to move the cursor through the current
    /// page or to send special application commands.
    ///
    /// If the DECCKM function is set, then the arrow keys send application
    /// sequences to the host.
    ///
    /// If the DECCKM function is reset, then the arrow keys send ANSI cursor
    /// sequences to the host.
    cursor_keys = 1,

    /// Change terminal wide between 80 and 132 column mode. When set
    /// (with ?40 set), resizes terminal to 132 columns and keeps it that
    /// wide. When unset, resizes to 80 columns.
    @"132_column" = 3,

    /// Reverses the foreground and background colors of all cells.
    reverse_colors = 5,

    /// If set, the origin of the coordinate system is relative to the
    /// current scroll region. If set the cursor is moved to the top left of
    /// the current scroll region.
    origin = 6,

    /// Enable or disable automatic line wrapping.
    autowrap = 7,

    /// Click-only (press) mouse reporting.
    mouse_event_x10 = 9,

    /// Set whether the cursor is visible or not.
    cursor_visible = 25,

    /// Enables or disables mode ?3. If disabled, the terminal will resize
    /// to the size of the window. If enabled, this will take effect when
    /// mode ?3 is set or unset.
    enable_mode_3 = 40,

    /// "Normal" mouse events: click/release, scroll
    mouse_event_normal = 1000,

    /// Same as normal mode but also send events for mouse motion
    /// while the button is pressed when the cell in the grid changes.
    mouse_event_button = 1002,

    /// Same as button mode but doesn't require a button to be pressed
    /// to track mouse movement.
    mouse_event_any = 1003,

    /// Report mouse position in the utf8 format to support larger screens.
    mouse_format_utf8 = 1005,

    /// Report mouse position in the SGR format.
    mouse_format_sgr = 1006,

    /// Report mouse scroll events as cursor up/down keys. Any other mouse
    /// mode overrides this.
    mouse_alternate_scroll = 1007,

    /// Report mouse position in the urxvt format.
    mouse_format_urxvt = 1015,

    /// Report mouse position in the SGR format as pixels, instead of cells.
    mouse_format_sgr_pixels = 1016,

    /// Alternate screen mode with save cursor and clear on enter.
    alt_screen_save_cursor_clear_enter = 1049,

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

/// The status line type for DECSSDT.
pub const StatusLineType = enum(u16) {
    none = 0,
    indicator = 1,
    host_writable = 2,

    // Non-exhaustive so that @intToEnum never fails for unsupported values.
    _,
};

/// The display to target for status updates (DECSASD).
pub const StatusDisplay = enum(u16) {
    main = 0,
    status_line = 1,

    // Non-exhaustive so that @intToEnum never fails for unsupported values.
    _,
};
