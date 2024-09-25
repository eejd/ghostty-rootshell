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
