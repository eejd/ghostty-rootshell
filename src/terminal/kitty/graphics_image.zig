const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const command = @import("graphics_command.zig");

/// Maximum width or height of an image. Taken directly from Kitty.
const max_dimension = 10000;

pub const Image = struct {
    id: u32 = 0,
    number: u32 = 0,
    data: []const u8,

    pub const Error = error{
        InvalidData,
        DimensionsRequired,
        DimensionsTooLarge,
        UnsupportedFormat,
    };

    /// Load an image from a transmission. The data in the command will be
    /// owned by the image if successful. Note that you still must deinit
    /// the command, all the state change will be done internally.
    pub fn load(alloc: Allocator, cmd: *command.Command) !Image {
        _ = alloc;

        const t = cmd.transmission().?;
        const img = switch (t.format) {
            .rgb => try loadPacked(3, t, cmd.data),
            .rgba => try loadPacked(4, t, cmd.data),
            else => return error.UnsupportedFormat,
        };

        // If we loaded an image successfully then we take ownership
        // of the command data.
        _ = cmd.toOwnedData();

        return img;
    }

    /// Load a package image format, i.e. RGB or RGBA.
    fn loadPacked(
        comptime bpp: comptime_int,
        t: command.Transmission,
        data: []const u8,
    ) !Image {
        if (t.width == 0 or t.height == 0) return error.DimensionsRequired;
        if (t.width > max_dimension or t.height > max_dimension) return error.DimensionsTooLarge;

        // Data length must be what we expect
        // NOTE: we use a "<" check here because Kitty itself doesn't validate
        // this and if we validate exact data length then various Kitty
        // applications fail because the test that Kitty documents itself
        // uses an invalid value.
        const expected_len = t.width * t.height * bpp;
        if (data.len < expected_len) return error.InvalidData;

        return Image{
            .id = t.image_id,
            .number = t.image_number,
            .data = data,
        };
    }

    pub fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(self.data);
    }
};

// This specifically tests we ALLOW invalid RGB data because Kitty
// documents that this should work.
test "image load with invalid RGB data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var data = try alloc.dupe(u8, "AAAA");
    errdefer alloc.free(data);

    // <ESC>_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA<ESC>\
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = data,
    };
    var img = try Image.load(alloc, &cmd);
    defer img.deinit(alloc);
}

test "image load with image too wide" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var data = try alloc.dupe(u8, "AAAA");
    defer alloc.free(data);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = max_dimension + 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = data,
    };
    try testing.expectError(error.DimensionsTooLarge, Image.load(alloc, &cmd));
}

test "image load with image too tall" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var data = try alloc.dupe(u8, "AAAA");
    defer alloc.free(data);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .height = max_dimension + 1,
            .width = 1,
            .image_id = 31,
        } },
        .data = data,
    };
    try testing.expectError(error.DimensionsTooLarge, Image.load(alloc, &cmd));
}
