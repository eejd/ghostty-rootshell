const std = @import("std");
const assert = std.debug.assert;
const CoreSurface = @import("../Surface.zig");

/// The possible actions an apprt has to react to.
pub const Action = union(enum) {
    new_window,

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
