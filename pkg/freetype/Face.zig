const Face = @This();

const std = @import("std");
const c = @import("c.zig");
const errors = @import("errors.zig");
const Error = errors.Error;
const intToError = errors.intToError;

handle: c.FT_Face,

pub fn deinit(self: Face) void {
    _ = c.FT_Done_Face(self.handle);
}
