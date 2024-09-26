const std = @import("std");
const assert = std.debug.assert;
const CoreSurface = @import("../Surface.zig");

/// The possible actions an apprt has to react to. Actions are one-way
/// messages that are sent to the app runtime to trigger some behavior.
///
/// Actions are very often key binding actions but can also be triggered
/// by lifecycle events. For example, the `quit_timer` action is not bindable.
///
/// Importantly, actions are generally OPTIONAL to implement by an apprt.
/// Required functionality is called directly on the runtime structure so
/// there is a compiler error if an action is not implemented.
pub const Action = union(enum) {
    /// Open a new window. The target determines whether properties such
    /// as font size should be inherited.
    new_window,

    /// Open a new tab. If the target is a surface it should be opened in
    /// the same window as the surface. If the target is the app then
    /// the tab should be opened in a new window.
    new_tab,

    /// Jump to a specific tab. Must handle the scenario that the tab
    /// value is invalid.
    goto_tab: GotoTab,

    /// Close all open windows.
    close_all_windows,

    /// Open the Ghostty configuration. This is platform-specific about
    /// what it means; it can mean opening a dedicated UI or just opening
    /// a file in a text editor.
    open_config,

    /// Called when there are no more surfaces and the app should quit
    /// after the configured delay. This can be cancelled by sending
    /// another quit_timer action with "stop". Multiple "starts" shouldn't
    /// happen and can be ignored or cause a restart it isn't that important.
    quit_timer: enum { start, stop },

    /// Set the secure input functionality on or off. "Secure input" means
    /// that the user is currently at some sort of prompt where they may be
    /// entering a password or other sensitive information. This can be used
    /// by the app runtime to change the appearance of the cursor, setup
    /// system APIs to not log the input, etc.
    secure_input: bool,

    /// The enum of keys in the tagged union.
    pub const Key = @typeInfo(Action).Union.tag_type.?;

    /// Returns the value type for the given key.
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).Union.fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }

        unreachable;
    }
};

/// The target for an action. This is generally the thing that had focus
/// while the action was made but the concept of "focus" is not guaranteed
/// since actions can also be triggered by timers, scripts, etc.
pub const Target = union(enum) {
    app,
    surface: *CoreSurface,
};

/// The tab to jump to. This is non-exhaustive so that integer values represent
/// the index (zero-based) of the tab to jump to. Negative values are special
/// values.
pub const GotoTab = enum(c_int) {
    previous = -1,
    next = -2,
    last = -3,
    _,
};
