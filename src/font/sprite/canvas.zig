//! This exposes primitives to draw 2D graphics and export the graphic to
//! a font atlas.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const pixman = @import("pixman");
const font = @import("../main.zig");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Line = struct {
    p1: Point,
    p2: Point,
};

pub const Box = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,

    pub fn rect(self: Box) Rect {
        const tl_x = @min(self.x1, self.x2);
        const tl_y = @min(self.y1, self.y2);
        const br_x = @max(self.x1, self.x2);
        const br_y = @max(self.y1, self.y2);
        return .{
            .x = tl_x,
            .y = tl_y,
            .width = @intCast(u32, br_x - tl_x),
            .height = @intCast(u32, br_y - tl_y),
        };
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Triangle = struct {
    p1: Point,
    p2: Point,
    p3: Point,
};

pub const Trapezoid = struct {
    top: i32,
    bottom: i32,
    left: Line,
    right: Line,
};

/// We only use alpha-channel so a pixel can only be "on" or "off".
pub const Color = enum(u8) {
    on = 255,
    off = 0,
    _,

    fn pixmanColor(self: Color) pixman.Color {
        // pixman uses u16 for color while our color value is u8 so we
        // scale it up proportionally.
        const max = @intToFloat(f32, std.math.maxInt(u8));
        const max_u16 = @intToFloat(f32, std.math.maxInt(u16));
        const unscaled = @intToFloat(f32, @enumToInt(self));
        const scaled = @floatToInt(u16, (unscaled * max_u16) / max);
        return .{ .red = 0, .green = 0, .blue = 0, .alpha = scaled };
    }
};

/// Composition operations that are supported.
pub const CompositionOp = enum {
    // Note: more can be added here as needed.

    destination_out,

    fn pixmanOp(self: CompositionOp) pixman.Op {
        return switch (self) {
            .destination_out => .out,
        };
    }
};

pub const Canvas = switch (font.options.backend) {
    .web_canvas => WebCanvasImpl,
    else => PixmanImpl,
};

const WebCanvasImpl = struct {};

const PixmanImpl = struct {
    /// The underlying image.
    image: *pixman.Image,

    /// The raw data buffer.
    data: []u32,

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
                .x2 = @intCast(i32, v.x + @intCast(i32, v.width)),
                .y2 = @intCast(i32, v.y + @intCast(i32, v.height)),
            },
        };

        self.image.fillBoxes(.src, color.pixmanColor(), boxes) catch {};
    }

    /// Draw and fill a trapezoid.
    pub fn trapezoid(self: *Canvas, t: Trapezoid) void {
        self.image.rasterizeTrapezoid(.{
            .top = pixman.Fixed.init(t.top),
            .bottom = pixman.Fixed.init(t.bottom),
            .left = .{
                .p1 = .{
                    .x = pixman.Fixed.init(t.left.p1.x),
                    .y = pixman.Fixed.init(t.left.p1.y),
                },
                .p2 = .{
                    .x = pixman.Fixed.init(t.left.p2.x),
                    .y = pixman.Fixed.init(t.left.p2.y),
                },
            },
            .right = .{
                .p1 = .{
                    .x = pixman.Fixed.init(t.right.p1.x),
                    .y = pixman.Fixed.init(t.right.p1.y),
                },
                .p2 = .{
                    .x = pixman.Fixed.init(t.right.p2.x),
                    .y = pixman.Fixed.init(t.right.p2.y),
                },
            },
        }, 0, 0);
    }

    /// Draw and fill a triangle.
    pub fn triangle(self: *Canvas, t: Triangle, color: Color) void {
        const tris = &[_]pixman.Triangle{
            .{
                .p1 = .{ .x = pixman.Fixed.init(t.p1.x), .y = pixman.Fixed.init(t.p1.y) },
                .p2 = .{ .x = pixman.Fixed.init(t.p2.x), .y = pixman.Fixed.init(t.p2.y) },
                .p3 = .{ .x = pixman.Fixed.init(t.p3.x), .y = pixman.Fixed.init(t.p3.y) },
            },
        };

        const src = pixman.Image.createSolidFill(color.pixmanColor()) catch return;
        defer _ = src.unref();
        self.image.compositeTriangles(.over, src, .a8, 0, 0, 0, 0, tris);
    }

    /// Composite one image on another.
    pub fn composite(self: *Canvas, op: CompositionOp, src: *const Canvas, dest: Rect) void {
        self.image.composite(
            op.pixmanOp(),
            src.image,
            null,
            0,
            0,
            0,
            0,
            @intCast(i16, dest.x),
            @intCast(i16, dest.y),
            @intCast(u16, dest.width),
            @intCast(u16, dest.height),
        );
    }

    /// Returns a copy of the raw pixel data in A8 format. The returned value
    /// must be freed by the caller. The returned data always has a stride
    /// exactly equivalent to the width.
    pub fn getData(self: *const Canvas, alloc: Allocator) ![]u8 {
        const width = @intCast(u32, self.image.getWidth());
        const height = @intCast(u32, self.image.getHeight());

        var result = try alloc.alloc(u8, height * width);
        errdefer alloc.free(result);

        // We want to convert our []u32 to []u8 since we use an 8bpp format
        var data_u32 = self.image.getData();
        const len_u8 = data_u32.len * 4;
        var real_data = @alignCast(@alignOf(u8), @ptrCast([*]u8, data_u32.ptr)[0..len_u8]);
        const real_stride = self.image.getStride();

        // Convert our strided data
        var r: u32 = 0;
        while (r < height) : (r += 1) {
            var c: u32 = 0;
            while (c < width) : (c += 1) {
                const src = r * @intCast(usize, real_stride) + c;
                const dst = (r * c) + c;
                result[dst] = real_data[src];
            }
        }

        return result;
    }
};
