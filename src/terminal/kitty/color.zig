const std = @import("std");
const terminal = @import("../main.zig");
const RGB = terminal.color.RGB;
const Terminator = terminal.osc.Terminator;

pub const OSC = struct {
    pub const Request = union(enum) {
        query: Kind,
        set: struct { key: Kind, color: RGB },
        reset: Kind,
    };

    /// list of requests
    list: std.ArrayList(Request),

    /// We must reply with the same string terminator (ST) as used in the
    /// request.
    terminator: Terminator = .st,
};

pub const Kind = enum(u9) {
    // Make sure that this stays in sync with the higest numbered enum
    // value.
    pub const max: u9 = 263;

    // These _must_ start at 256 since enum values 0-255 are reserved
    // for the palette.
    foreground = 256,
    background = 257,
    selection_foreground = 258,
    selection_background = 259,
    cursor = 260,
    cursor_text = 261,
    visual_bell = 262,
    second_transparent_background = 263,
    _,

    /// Return the palette index that this kind is representing
    /// or null if its a special color.
    pub fn palette(self: Kind) ?u8 {
        return std.math.cast(u8, @intFromEnum(self)) orelse null;
    }

    pub fn format(
        self: Kind,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;

        // Format as a number if its a palette color otherwise
        // format as a string.
        if (self.palette()) |idx| {
            try writer.print("{}", .{idx});
        } else {
            try writer.print("{s}", .{@tagName(self)});
        }
    }
};

test "OSC: kitty color protocol kind" {
    const info = @typeInfo(Kind);

    try std.testing.expectEqual(false, info.Enum.is_exhaustive);

    var min: usize = std.math.maxInt(info.Enum.tag_type);
    var max: usize = 0;

    inline for (info.Enum.fields) |field| {
        if (field.value > max) max = field.value;
        if (field.value < min) min = field.value;
    }

    try std.testing.expect(min >= 256);
    try std.testing.expect(max == Kind.max);
}

test "OSC: kitty color protocol kind string" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    {
        const actual = try std.fmt.bufPrint(&buf, "{}", .{Kind.foreground});
        try testing.expectEqualStrings("foreground", actual);
    }
    {
        const actual = try std.fmt.bufPrint(&buf, "{}", .{@as(Kind, @enumFromInt(42))});
        try testing.expectEqualStrings("42", actual);
    }
}
