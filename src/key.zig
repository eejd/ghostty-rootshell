const std = @import("std");

/// A single binding.
pub const Binding = struct {
    /// The key that has to be pressed for this binding to take action.
    key: Key = .invalid,

    /// The key modifiers that must be active for this to match.
    mods: Mods = .{},

    /// The action to take if this binding matches
    action: Action,

    pub const Error = error{
        InvalidFormat,
    };

    /// Parse the format "ctrl+a=csi:A" into a binding. The format is
    /// specifically "trigger=action". Trigger is a "+"-delimited series of
    /// modifiers and keys. Action is the action name and optionally a
    /// parameter after a colon, i.e. "csi:A" or "ignore".
    pub fn parse(input: []const u8) !Binding {
        // NOTE(mitchellh): This is not the most efficient way to do any
        // of this, I welcome any improvements here!

        // Find the first = which splits are mapping into the trigger
        // and action, respectively.
        const eqlIdx = std.mem.indexOf(u8, input, "=") orelse return Error.InvalidFormat;

        // Accumulator for our result
        var result: Binding = .{ .action = undefined };

        // Determine our trigger conditions by parsing the part before
        // the "=", i.e. "ctrl+shift+a" or "a"
        var iter = std.mem.tokenize(u8, input[0..eqlIdx], "+");
        trigger: while (iter.next()) |part| {
            // All parts must be non-empty
            if (part.len == 0) return Error.InvalidFormat;

            // Check if its a modifier
            const modsInfo = @typeInfo(Mods).Struct;
            inline for (modsInfo.fields) |field| {
                if (field.field_type == bool) {
                    if (std.mem.eql(u8, part, field.name)) {
                        // Repeat not allowed
                        if (@field(result.mods, field.name)) return Error.InvalidFormat;

                        @field(result.mods, field.name) = true;
                        continue :trigger;
                    }
                }
            }

            // Check if its a key
            const keysInfo = @typeInfo(Key).Enum;
            inline for (keysInfo.fields) |field| {
                if (!std.mem.eql(u8, field.name, "invalid")) {
                    if (std.mem.eql(u8, part, field.name)) {
                        // Repeat not allowed
                        if (result.key != .invalid) return Error.InvalidFormat;

                        result.key = @field(Key, field.name);
                        continue :trigger;
                    }
                }
            }

            // We didn't recognize this value
            return Error.InvalidFormat;
        }

        // Find a matching action
        result.action = action: {
            // Split our action by colon. A colon may not exist for some
            // actions so it is optional. The part preceding the colon is the
            // action name.
            const actionRaw = input[eqlIdx + 1 ..];
            const colonIdx = std.mem.indexOf(u8, actionRaw, ":");
            const action = actionRaw[0..(colonIdx orelse actionRaw.len)];

            // An action name is always required
            if (action.len == 0) return Error.InvalidFormat;

            const actionInfo = @typeInfo(Action).Union;
            inline for (actionInfo.fields) |field| {
                if (std.mem.eql(u8, action, field.name)) {
                    // If the field type is void we expect no value
                    switch (field.field_type) {
                        void => {
                            if (colonIdx != null) return Error.InvalidFormat;
                            break :action @unionInit(Action, field.name, {});
                        },

                        []const u8 => {
                            const idx = colonIdx orelse return Error.InvalidFormat;
                            const param = actionRaw[idx + 1 ..];
                            break :action @unionInit(Action, field.name, param);
                        },

                        else => unreachable,
                    }
                }
            }

            return Error.InvalidFormat;
        };

        return result;
    }

    test "parse: triggers" {
        const testing = std.testing;

        // single character
        try testing.expectEqual(
            Binding{ .key = .a, .action = .{ .ignore = {} } },
            try parse("a=ignore"),
        );

        // single modifier
        try testing.expectEqual(Binding{
            .mods = .{ .shift = true },
            .key = .a,
            .action = .{ .ignore = {} },
        }, try parse("shift+a=ignore"));
        try testing.expectEqual(Binding{
            .mods = .{ .ctrl = true },
            .key = .a,
            .action = .{ .ignore = {} },
        }, try parse("ctrl+a=ignore"));

        // multiple modifier
        try testing.expectEqual(Binding{
            .mods = .{ .shift = true, .ctrl = true },
            .key = .a,
            .action = .{ .ignore = {} },
        }, try parse("shift+ctrl+a=ignore"));

        // key can come before modifier
        try testing.expectEqual(Binding{
            .mods = .{ .shift = true },
            .key = .a,
            .action = .{ .ignore = {} },
        }, try parse("a+shift=ignore"));

        // invalid key
        try testing.expectError(Error.InvalidFormat, parse("foo=ignore"));

        // repeated control
        try testing.expectError(Error.InvalidFormat, parse("shift+shift+a=ignore"));

        // multiple character
        try testing.expectError(Error.InvalidFormat, parse("a+b=ignore"));
    }

    test "parse: action" {
        const testing = std.testing;

        // invalid action
        try testing.expectError(Error.InvalidFormat, parse("a=nopenopenope"));

        // no parameters
        try testing.expectEqual(
            Binding{ .key = .a, .action = .{ .ignore = {} } },
            try parse("a=ignore"),
        );
        try testing.expectError(Error.InvalidFormat, parse("a=ignore:A"));

        // parameter
        {
            const binding = try parse("a=csi:A");
            try testing.expect(binding.action == .csi);
            try testing.expectEqualStrings("A", binding.action.csi);
        }
    }
};

/// The set of actions that a keybinding can take.
pub const Action = union(enum) {
    /// Ignore this key combination, don't send it to the child process,
    /// just black hole it.
    ignore: void,

    /// Send a CSI sequence. The value should be the CSI sequence
    /// without the CSI header ("ESC ]" or "\x1b]").
    csi: []const u8,
};

/// A bitmask for all key modifiers. This is taken directly from the
/// GLFW representation, but we use this generically.
pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,
};

/// The set of keys that can map to keybindings. These have no fixed enum
/// values because we map platform-specific keys to this set. Note that
/// this only needs to accomodate what maps to a key. If a key is not bound
/// to anything and the key can be mapped to a printable character, then that
/// unicode character is sent directly to the pty.
pub const Key = enum {
    invalid,

    // a-z
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // To support more keys (there are obviously more!) add them here
    // and ensure the mapping is up to date in the Window key handler.
};

test {
    std.testing.refAllDecls(@This());
}
