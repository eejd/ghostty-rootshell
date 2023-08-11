//! This is the render state that is given to a renderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DevMode = @import("../DevMode.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Thread.Mutex,

/// Cursor configuration for rendering
cursor: Cursor,

/// The terminal data.
terminal: *terminal.Terminal,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// The devmode data.
devmode: ?*const DevMode = null,

pub const Cursor = struct {
    /// Current cursor style. This can be set by escape sequences. To get
    /// the default style, the config has to be referenced.
    style: terminal.CursorStyle = .default,

    /// Whether the cursor is visible at all. This should not be used for
    /// "blink" settings, see "blink" for that. This is used to turn the
    /// cursor ON or OFF.
    visible: bool = true,
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoint to render as preedit text. We only support single
    /// codepoint for now. In theory this can be multiple codepoints but
    /// that is left as a future exercise.
    ///
    /// This can also be "0" in which case we can know we're in a preedit
    /// mode but we don't have any preedit text to render.
    codepoint: u21 = 0,
};
