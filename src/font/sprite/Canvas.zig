//! This exposes primitives to draw 2D graphics and export the graphic to
//! a font atlas.
const Canvas = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const pixman = @import("pixman");
const font = @import("../main.zig");

/// The underlying image.
image: *pixman.Image,

/// The raw data buffer.
data: []u32,

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// We only use alpha-channel so a pixel can only be "on" or "off".
pub const Color = enum {
    on,
    off,

    fn pixmanColor(self: Color) pixman.Color {
        return switch (self) {
            .on => .{ .red = 0xFFFF, .green = 0xFFFF, .blue = 0xFFFF, .alpha = 0xFFFF },
            .off => .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 },
        };
    }
};

pub fn init(alloc: Allocator, width: u32, height: u32) !Canvas {
    // Determine the config for our image buffer. The images we draw
    // for boxes are always 8bpp
    const format: pixman.FormatCode = .a8;
    const stride = format.strideForWidth(width);
    const len = @intCast(usize, stride * @intCast(c_int, height));

    // Allocate our buffer. pixman uses []u32 so we divide our length
    // by 4 since u32 / u8 = 4.
    var data = try alloc.alloc(u32, len / 4);
    errdefer alloc.free(data);
    std.mem.set(u32, data, 0);

    // Create the image we'll draw to
    const img = try pixman.Image.createBitsNoClear(
        format,
        @intCast(c_int, width),
        @intCast(c_int, height),
        data.ptr,
        stride,
    );
    errdefer _ = img.unref();

    return Canvas{
        .image = img,
        .data = data,
    };
}

pub fn deinit(self: *Canvas, alloc: Allocator) void {
    alloc.free(self.data);
    _ = self.image.unref();
    self.* = undefined;
}

/// Write the data in this drawing to the atlas.
pub fn writeAtlas(self: *Canvas, alloc: Allocator, atlas: *font.Atlas) !font.Atlas.Region {
    assert(atlas.format == .greyscale);

    const width = @intCast(u32, self.image.getWidth());
    const height = @intCast(u32, self.image.getHeight());
    const region = try atlas.reserve(alloc, width, height);
    if (region.width > 0 and region.height > 0) {
        const depth = atlas.format.depth();

        // Convert our []u32 to []u8 since we use 8bpp formats
        const stride = self.image.getStride();
        const data = @alignCast(
            @alignOf(u8),
            @ptrCast([*]u8, self.data.ptr)[0 .. self.data.len * 4],
        );

        // We can avoid a buffer copy if our atlas width and bitmap
        // width match and the bitmap pitch is just the width (meaning
        // the data is tightly packed).
        const needs_copy = !(width * depth == stride);

        // If we need to copy the data, we copy it into a temporary buffer.
        const buffer = if (needs_copy) buffer: {
            var temp = try alloc.alloc(u8, width * height * depth);
            var dst_ptr = temp;
            var src_ptr = data.ptr;
            var i: usize = 0;
            while (i < height) : (i += 1) {
                std.mem.copy(u8, dst_ptr, src_ptr[0 .. width * depth]);
                dst_ptr = dst_ptr[width * depth ..];
                src_ptr += @intCast(usize, stride);
            }
            break :buffer temp;
        } else data[0..(width * height * depth)];
        defer if (buffer.ptr != data.ptr) alloc.free(buffer);

        // Write the glyph information into the atlas
        assert(region.width == width);
        assert(region.height == height);
        atlas.set(region, buffer);
    }

    return region;
}

/// Draw and fill a rectangle. This is the main primitive for drawing
/// lines as well (which are just generally skinny rectangles...)
pub fn rect(self: *Canvas, v: Rect, color: Color) void {
    const boxes = &[_]pixman.Box32{
        .{
            .x1 = @intCast(i32, v.x),
            .y1 = @intCast(i32, v.y),
            .x2 = @intCast(i32, v.x + v.width),
            .y2 = @intCast(i32, v.y + v.height),
        },
    };

    self.image.fillBoxes(.src, color.pixmanColor(), boxes) catch {};
}
