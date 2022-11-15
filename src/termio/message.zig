const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

/// The messages that can be sent to an IO thread.
///
/// This is not a tiny structure (~40 bytes at the time of writing this comment),
/// but the messages are IO thread sends are also very few. At the current size
/// we can queue 26,000 messages before consuming a MB of RAM.
pub const Message = union(enum) {
    /// Resize the window.
    resize: struct {
        /// The grid size for the given screen size with padding applied.
        grid_size: renderer.GridSize,

        /// The full screen (drawable) size. This does NOT include padding.
        /// This should be sent on to the renderer.
        screen_size: renderer.ScreenSize,

        /// The padding, so that the terminal implementation can subtract
        /// this to send to the pty.
        padding: renderer.Padding,
    },

    /// Write where the data fits in the union.
    write_small: WriteReq.Small,

    /// Write where the data pointer is stable.
    write_stable: []const u8,

    /// Write where the data is allocated and must be freed.
    write_alloc: WriteReq.Alloc,

    /// Return a write request for the given data. This will use
    /// write_small if it fits or write_alloc otherwise. This should NOT
    /// be used for stable pointers which can be manually set to write_stable.
    pub fn writeReq(alloc: Allocator, data: anytype) !Message {
        switch (@typeInfo(@TypeOf(data))) {
            .Pointer => |info| {
                assert(info.size == .Slice);
                assert(info.child == u8);

                // If it fits in our small request, do that.
                if (data.len <= WriteReq.Small.Max) {
                    var buf: WriteReq.Small.Array = undefined;
                    std.mem.copy(u8, &buf, data);
                    return Message{
                        .write_small = .{
                            .data = buf,
                            .len = @intCast(u8, data.len),
                        },
                    };
                }

                // Otherwise, allocate
                var buf = try alloc.dupe(u8, data);
                errdefer alloc.free(buf);
                return Message{
                    .write_alloc = .{
                        .alloc = alloc,
                        .data = buf,
                    },
                };
            },

            else => unreachable,
        }
    }

    /// Represents a write request.
    pub const WriteReq = union(enum) {
        pub const Small = struct {
            pub const Max = 38;
            pub const Array = [Max]u8;
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
};

test {
    std.testing.refAllDecls(@This());
}

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(Message));
}

test "Message.writeReq small" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input = "hello!";
    const io = try Message.writeReq(alloc, @as([]const u8, input));
    try testing.expect(io == .write_small);
}

test "Message.writeReq alloc" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input = "hello! " ** 100;
    const io = try Message.writeReq(alloc, @as([]const u8, input));
    try testing.expect(io == .write_alloc);
    io.write_alloc.alloc.free(io.write_alloc.data);
}
