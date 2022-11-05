const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

/// The messages that can be sent to an IO thread.
pub const IO = union(enum) {
    /// Resize the window.
    resize: struct {
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    },

    /// Write where the data fits in the union.
    write_small: WriteReq.Small,

    /// Write where the data pointer is stable.
    write_stable: []const u8,
};

/// Represents a write request.
pub const WriteReq = union(enum) {
    pub const Small = struct {
        pub const Array = [22]u8;
        data: Array,
        len: u8,
    };

    pub const Alloc = struct {
        alloc: Allocator,
        data: []u8,
    };

    /// A small write where the data fits into this union size.
    small: Small,

    /// A stable pointer so we can just pass the slice directly through.
    /// This is useful i.e. for const data.
    stable: []const u8,

    /// Allocated and must be freed with the provided allocator. This
    /// should be rarely used.
    alloc: Alloc,
};

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 24), @sizeOf(IO));
}
