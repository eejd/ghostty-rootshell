const std = @import("std");
const c = @import("c.zig");
const pixman = @import("main.zig");

pub const Image = opaque {
    pub inline fn createBitsNoClear(
        format: pixman.FormatCode,
        width: c_int,
        height: c_int,
        bits: [*]u32,
        stride: c_int,
    ) ?*Image {
        return @ptrCast(?*Image, c.pixman_image_create_bits_no_clear(
            @enumToInt(format),
            width,
            height,
            bits,
            stride,
        ));
    }

    pub inline fn unref(self: *Image) bool {
        return c.pixman_image_unref(@ptrCast(*c.pixman_image_t, self)) == 1;
    }
};

test "create and destroy" {
    const testing = std.testing;

    const width = 10;
    const height = 10;
    const format: pixman.FormatCode = .g1;
    const stride = format.strideForWidth(width);
    var bits: [width * height]u32 = undefined;
    const img = Image.createBitsNoClear(.g1, width, height, &bits, stride);
    try testing.expect(img != null);
    try testing.expect(img.?.unref());
}
