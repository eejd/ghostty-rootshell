//! This exposes primitives to draw 2D graphics and export the graphic to
//! a font atlas.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const font = @import("../main.zig");

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Line = struct {
    p0: Point,
    p1: Point,
};

pub const Box = struct {
    p0: Point,
    p1: Point,

    pub fn rect(self: Box) Rect {
        const tl_x = @min(self.p0.x, self.p1.x);
        const tl_y = @min(self.p0.y, self.p1.y);
        const br_x = @max(self.p0.x, self.p1.x);
        const br_y = @max(self.p0.y, self.p1.y);
        return .{
            .x = tl_x,
            .y = tl_y,
            .width = br_x - tl_x,
            .height = br_y - tl_y,
        };
    }
};

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const Triangle = struct {
    p0: Point,
    p1: Point,
    p2: Point,
};

pub const Quad = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
};

/// We only use alpha-channel so a pixel can only be "on" or "off".
pub const Color = enum(u8) {
    on = 255,
    off = 0,
    _,
};

pub const Canvas = struct {
    /// The underlying z2d surface.
    sfc: z2d.Surface,

    alloc: Allocator,

    pub fn init(alloc: Allocator, width: u32, height: u32) !Canvas {
        // Create the surface we'll be using.
        const sfc = try z2d.Surface.initPixel(
            .{ .alpha8 = .{ .a = 0 } },
            alloc,
            @intCast(width),
            @intCast(height),
        );

        return .{
            .sfc = sfc,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Canvas, alloc: Allocator) void {
        _ = alloc;
        self.sfc.deinit();
        self.* = undefined;
    }

    /// Write the data in this drawing to the atlas.
    pub fn writeAtlas(self: *Canvas, alloc: Allocator, atlas: *font.Atlas) !font.Atlas.Region {
        assert(atlas.format == .grayscale);

        const width = @as(u32, @intCast(self.sfc.getWidth()));
        const height = @as(u32, @intCast(self.sfc.getHeight()));

        // Allocate our texture atlas region
        const region = region: {
            // We need to add a 1px padding to the font so that we don't
            // get fuzzy issues when blending textures.
            const padding = 1;

            // Get the full padded region
            var region = try atlas.reserve(
                alloc,
                width + (padding * 2), // * 2 because left+right
                height + (padding * 2), // * 2 because top+bottom
            );

            // Modify the region so that we remove the padding so that
            // we write to the non-zero location. The data in an Altlas
            // is always initialized to zero (Atlas.clear) so we don't
            // need to worry about zero-ing that.
            region.x += padding;
            region.y += padding;
            region.width -= padding * 2;
            region.height -= padding * 2;
            break :region region;
        };

        if (region.width > 0 and region.height > 0) {
            const buffer: []u8 = @ptrCast(self.sfc.image_surface_alpha8.buf);

            // Write the glyph information into the atlas
            assert(region.width == width);
            assert(region.height == height);
            atlas.set(region, buffer);
        }

        return region;
    }

    /// Draw and fill a single pixel
    pub fn pixel(self: *Canvas, x: u32, y: u32, color: Color) void {
        self.sfc.putPixel(
            @intCast(x),
            @intCast(y),
            .{ .alpha8 = .{ .a = @intFromEnum(color) } },
        ) catch {
            // If we try to set out of range this will fail.
            // We just silently ignore that.
        };
    }

    /// Draw and fill a rectangle. This is the main primitive for drawing
    /// lines as well (which are just generally skinny rectangles...)
    pub fn rect(self: *Canvas, v: Rect, color: Color) void {
        const x0: usize = @intFromFloat(v.x);
        const x1: usize = @intFromFloat(v.x + v.width);
        const y0: usize = @intFromFloat(v.y);
        const y1: usize = @intFromFloat(v.y + v.height);

        for (y0..y1) |y| {
            for (x0..x1) |x| {
                self.pixel(
                    @intCast(x),
                    @intCast(y),
                    color,
                );
            }
        }
    }

    /// Draw and fill a quad.
    pub fn quad(self: *Canvas, q: Quad, color: Color) !void {
        var ctx: z2d.Context = .{
            .surface = self.sfc,
            .pattern = .{
                .opaque_pattern = .{
                    .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
                },
            },
        };

        var path = z2d.Path.init(self.alloc);
        defer path.deinit();

        try path.moveTo(q.p0.x, q.p0.y);
        try path.lineTo(q.p1.x, q.p1.y);
        try path.lineTo(q.p2.x, q.p2.y);
        try path.lineTo(q.p3.x, q.p3.y);
        try path.close();

        try ctx.fill(self.alloc, path);
    }

    /// Draw and fill a triangle.
    pub fn triangle(self: *Canvas, t: Triangle, color: Color) !void {
        var ctx: z2d.Context = .{
            .surface = self.sfc,
            .pattern = .{
                .opaque_pattern = .{
                    .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
                },
            },
        };

        var path = z2d.Path.init(self.alloc);
        defer path.deinit();

        try path.moveTo(t.p0.x, t.p0.y);
        try path.lineTo(t.p1.x, t.p1.y);
        try path.lineTo(t.p2.x, t.p2.y);
        try path.close();

        try ctx.fill(self.alloc, path);
    }

    /// Stroke a line.
    pub fn line(self: *Canvas, l: Line, thickness: f64, color: Color) !void {
        var ctx: z2d.Context = .{
            .surface = self.sfc,
            .pattern = .{
                .opaque_pattern = .{
                    .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
                },
            },
            .line_width = thickness,
            .line_cap_mode = .round,
        };

        var path = z2d.Path.init(self.alloc);
        defer path.deinit();

        try path.moveTo(l.p0.x, l.p0.y);
        try path.lineTo(l.p1.x, l.p1.y);

        try ctx.stroke(self.alloc, path);
    }

    pub fn invert(self: *Canvas) void {
        for (std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf)) |*v| {
            v.* = 255 - v.*;
        }
    }
};
