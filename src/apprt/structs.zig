/// ContentScale is the ratio between the current DPI and the platform's
/// default DPI. This is used to determine how much certain rendered elements
/// need to be scaled up or down.
pub const ContentScale = struct {
    x: f32,
    y: f32,
};

/// The size of the surface in pixels.
pub const SurfaceSize = struct {
    width: u32,
    height: u32,
};

/// The position of the cursor in pixels.
pub const CursorPos = struct {
    x: f32,
    y: f32,
};

/// Input Method Editor (IME) position.
pub const IMEPos = struct {
    x: f64,
    y: f64,
};

/// The clipboard type.
///
/// If this is changed, you must also update ghostty.h
pub const Clipboard = enum(u1) {
    standard = 0, // ctrl+c/v
    selection = 1, // also known as the "primary" clipboard
};

/// Clipboard request. This is used to request clipboard contents and must
/// be sent as a response to a ClipboardRequest event.
pub const ClipboardRequest = union(enum) {
    /// A direct paste of clipboard contents.
    paste: void,

    /// A request to write clipboard contents via OSC 52.
    osc_52: u8,
};

/// The reason for displaying a clipboard prompt to the user
pub const ClipboardPromptReason = enum(i32) {
    /// For pasting data only. Pasted data contains potentially unsafe
    /// characters
    unsafe = 1,

    /// The user must authorize the application to read from the clipboard
    read = 2,

    /// The user must authorize the application to write to the clipboard
    write = 3,

    _,
};
