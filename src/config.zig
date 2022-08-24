const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const inputpkg = @import("input.zig");

/// Config is the main config struct. These fields map directly to the
/// CLI flag names hence we use a lot of `@""` syntax to support hyphens.
pub const Config = struct {
    /// Font size
    /// TODO: this default size is too big, what we need to do is use a reasonable
    /// size and then mult a high-DPI scaling factor. This is only high because
    /// all our test machines are high-DPI right now.
    @"font-size": u8 = 32,

    /// Background color for the window.
    background: Color = .{ .r = 0, .g = 0, .b = 0 },

    /// Foreground color for the window.
    foreground: Color = .{ .r = 0xFF, .g = 0xA5, .b = 0 },

    /// The command to run, usually a shell. If this is not an absolute path,
    /// it'll be looked up in the PATH.
    command: ?[]const u8 = null,

    /// Key bindings. The format is "trigger=action". Duplicate triggers
    /// will overwrite previously set values.
    ///
    /// Trigger: "+"-separated list of keys and modifiers. Example:
    /// "ctrl+a", "ctrl+shift+b", "up". Some notes:
    ///
    ///   - modifiers cannot repeat, "ctrl+ctrl+a" is invalid.
    ///   - modifers and key scan be in any order, "shift+a+ctrl" is weird,
    ///     but valid.
    ///   - only a single key input is allowed, "ctrl+a+b" is invalid.
    ///
    /// Action is the action to take when the trigger is satisfied. It takes
    /// the format "action" or "action:param". The latter form is only valid
    /// if the action requires a parameter.
    ///
    ///   - "ignore" - Do nothing, ignore the key input. This can be used to
    ///     black hole certain inputs to have no effect.
    ///   - "unbind" - Remove the binding. This makes it so the previous action
    ///     is removed, and the key will be sent through to the child command
    ///     if it is printable.
    ///   - "csi:text" - Send a CSI sequence. i.e. "csi:A" sends "cursor up".
    ///
    /// Some notes for the action:
    ///
    ///   - The parameter is taken as-is after the ":". Double quotes or
    ///     other mechanisms are included and NOT parsed. If you want to
    ///     send a string value that includes spaces, wrap the entire
    ///     trigger/action in double quotes. Example: --keybind="up=csi:A B"
    ///
    keybind: Keybinds = .{},

    /// Additional configuration files to read.
    @"config-file": RepeatableString = .{},

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

/// Color represents a color using RGB.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const Error = error{
        InvalidFormat,
    };

    pub fn parseCLI(input: ?[]const u8) !Color {
        return fromHex(input orelse return error.ValueRequired);
    }

    /// fromHex parses a color from a hex value such as #RRGGBB. The "#"
    /// is optional.
    pub fn fromHex(input: []const u8) !Color {
        // Trim the beginning '#' if it exists
        const trimmed = if (input.len != 0 and input[0] == '#') input[1..] else input;

        // We expect exactly 6 for RRGGBB
        if (trimmed.len != 6) return Error.InvalidFormat;

        // Parse the colors two at a time.
        var result: Color = undefined;
        comptime var i: usize = 0;
        inline while (i < 6) : (i += 2) {
            const v: u8 =
                ((try std.fmt.charToDigit(trimmed[i], 16)) * 16) +
                try std.fmt.charToDigit(trimmed[i + 1], 16);

            @field(result, switch (i) {
                0 => "r",
                2 => "g",
                4 => "b",
                else => unreachable,
            }) = v;
        }

        return result;
    }

    test "fromHex" {
        const testing = std.testing;

        try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.fromHex("#000000"));
        try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("#0A0B0C"));
        try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("0A0B0C"));
        try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.fromHex("FFFFFF"));
    }
};

/// RepeatableString is a string value that can be repeated to accumulate
/// a list of strings. This isn't called "StringList" because I find that
/// sometimes leads to confusion that it _accepts_ a list such as
/// comma-separated values.
pub const RepeatableString = struct {
    const Self = @This();

    // Allocator for the list is the arena for the parent config.
    list: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse return error.ValueRequired;
        try self.list.append(alloc, value);
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        try list.parseCLI(alloc, "B");

        try testing.expectEqual(@as(usize, 2), list.list.items.len);
    }
};

/// Stores a set of keybinds.
pub const Keybinds = struct {
    set: inputpkg.Binding.Set = .{},

    pub fn parseCLI(self: *Keybinds, alloc: Allocator, input: ?[]const u8) !void {
        var copy: ?[]u8 = null;
        var value = value: {
            const value = input orelse return error.ValueRequired;

            // If we don't have a colon, use the value as-is, no copy
            if (std.mem.indexOf(u8, value, ":") == null)
                break :value value;

            // If we have a colon, we copy the whole value for now. We could
            // do this more efficiently later if we wanted to.
            const buf = try alloc.alloc(u8, value.len);
            copy = buf;

            std.mem.copy(u8, buf, value);
            break :value buf;
        };
        errdefer if (copy) |v| alloc.free(v);

        const binding = try inputpkg.Binding.parse(value);
        switch (binding.action) {
            .unbind => self.set.remove(binding.trigger),
            else => try self.set.put(alloc, binding.trigger, binding.action),
        }
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var set: Keybinds = .{};
        try set.parseCLI(alloc, "shift+a=copy_to_clipboard");
        try set.parseCLI(alloc, "shift+a=csi:hello");
    }
};

test {
    std.testing.refAllDecls(@This());
}
