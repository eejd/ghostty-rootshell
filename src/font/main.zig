const std = @import("std");

pub const Face = @import("Face.zig");
pub const Family = @import("Family.zig");
pub const Group = @import("Group.zig");
pub const GroupCache = @import("GroupCache.zig");
pub const Glyph = @import("Glyph.zig");
pub const FallbackSet = @import("FallbackSet.zig");
pub const Library = @import("Library.zig");

/// The styles that a family can take.
pub const Style = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

/// Returns the UTF-32 codepoint for the given value.
pub fn codepoint(v: anytype) u32 {
    // We need a UTF32 codepoint for freetype
    return switch (@TypeOf(v)) {
        u32 => v,
        comptime_int, u8 => @intCast(u32, v),
        []const u8 => @intCast(u32, try std.unicode.utfDecode(v)),
        else => @compileError("invalid codepoint type"),
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
