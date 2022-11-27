//! This file renders underline sprites. To draw underlines, we render the
//! full cell-width as a sprite and then draw it as a separate pass to the
//! text.
//!
//! We used to render the underlines directly in the GPU shaders but its
//! annoying to support multiple types of underlines and its also annoying
//! to maintain and debug another set of shaders for each renderer instead of
//! just relying on the glyph system we already need to support for text
//! anyways.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Sprite = font.sprite.Sprite;
const Atlas = @import("../../Atlas.zig");

/// Draw an underline.
pub fn renderGlyph(
    alloc: Allocator,
    atlas: *Atlas,
    sprite: Sprite,
    width: u32,
    height: u32,
    line_pos: u32,
    line_thickness: u32,
) !font.Glyph {
    // Create the canvas we'll use to draw. We draw the underline in
    // a full cell size and position it according to "pos".
    var canvas = try font.sprite.Canvas.init(alloc, width, height);
    defer canvas.deinit(alloc);

    // Perform the actual drawing
    (Draw{
        .width = width,
        .height = height,
        .pos = line_pos,
        .thickness = line_thickness,
    }).draw(&canvas, sprite);

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    // Our coordinates start at the BOTTOM for our renderers so we have to
    // specify an offset of the full height because we rendered a full size
    // cell.
    const offset_y = @intCast(i32, height);

    return font.Glyph{
        .width = width,
        .height = height,
        .offset_x = 0,
        .offset_y = offset_y,
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = @intToFloat(f32, width),
    };
}

/// Stores drawing state.
const Draw = struct {
    width: u32,
    height: u32,
    pos: u32,
    thickness: u32,

    /// Draw a specific underline sprite to the canvas.
    fn draw(self: Draw, canvas: *font.sprite.Canvas, sprite: Sprite) void {
        switch (sprite) {
            .underline => self.drawSingle(canvas),
            .underline_double => self.drawDouble(canvas),
            .underline_dotted => self.drawDotted(canvas),
            .underline_dashed => self.drawDashed(canvas),
        }
    }

    /// Draw a single underline.
    fn drawSingle(self: Draw, canvas: *font.sprite.Canvas) void {
        canvas.rect(.{
            .x = 0,
            .y = self.pos,
            .width = self.width,
            .height = self.thickness,
        }, .on);
    }

    /// Draw a double underline.
    fn drawDouble(self: Draw, canvas: *font.sprite.Canvas) void {
        canvas.rect(.{
            .x = 0,
            .y = self.pos,
            .width = self.width,
            .height = self.thickness,
        }, .on);

        canvas.rect(.{
            .x = 0,
            .y = self.pos + (self.thickness * 2),
            .width = self.width,
            .height = self.thickness,
        }, .on);
    }

    /// Draw a dotted underline.
    fn drawDotted(self: Draw, canvas: *font.sprite.Canvas) void {
        const dot_width = @max(self.thickness, 3);
        const dot_count = self.width / dot_width;
        var i: u32 = 0;
        while (i < dot_count) : (i += 2) {
            canvas.rect(.{
                .x = i * dot_width,
                .y = self.pos,
                .width = dot_width,
                .height = self.thickness,
            }, .on);
        }
    }

    /// Draw a dashed underline.
    fn drawDashed(self: Draw, canvas: *font.sprite.Canvas) void {
        const dash_width = self.width / 3 + 1;
        const dash_count = (self.width / dash_width) + 1;
        var i: u32 = 0;
        while (i < dash_count) : (i += 2) {
            canvas.rect(.{
                .x = i * dash_width,
                .y = self.pos,
                .width = dash_width,
                .height = self.thickness,
            }, .on);
        }
    }
};

test "single" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas_greyscale = try Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    _ = try renderGlyph(
        alloc,
        &atlas_greyscale,
        .underline,
        36,
        18,
        9,
        2,
    );
}
