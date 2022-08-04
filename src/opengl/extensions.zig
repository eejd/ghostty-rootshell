const std = @import("std");
const c = @import("c.zig");
const errors = @import("errors.zig");

/// Returns the number of extensions.
pub fn len() !u32 {
    var n: c.GLint = undefined;
    c.glGetIntegerv(c.GL_NUM_EXTENSIONS, &n);
    try errors.getError();
    return @intCast(u32, n);
}

/// Returns an iterator for the extensions.
pub fn iterator() !Iterator {
    return Iterator{ .len = try len() };
}

/// Iterator for the available extensions.
pub const Iterator = struct {
    /// The total number of extensions.
    len: c.GLuint = 0,
    i: c.GLuint = 0,

    pub fn next(self: *Iterator) !?[]const u8 {
        if (self.i >= self.len) return null;
        const res = c.glGetStringi(c.GL_EXTENSIONS, self.i);
        try errors.getError();
        self.i += 1;
        return std.mem.sliceTo(res, 0);
    }
};
