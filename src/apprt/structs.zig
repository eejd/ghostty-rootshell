/// ContentScale is the ratio between the current DPI and the platform's
/// default DPI. This is used to determine how much certain rendered elements
/// need to be scaled up or down.
pub const ContentScale = struct {
    x: f32,
    y: f32,
};

/// The size of the window in pixels.
pub const WindowSize = struct {
    width: u32,
    height: u32,
};

/// The position of the cursor in pixels.
pub const CursorPos = struct {
    x: f32,
    y: f32,
};
