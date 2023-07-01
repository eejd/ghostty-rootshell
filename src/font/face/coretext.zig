const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    /// Our font face
    font: *macos.text.Font,

    /// Harfbuzz font corresponding to this face.
    hb_font: harfbuzz.Font,

    /// The presentation for this font.
    presentation: font.Presentation,

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.face.Metrics,

    /// Initialize a CoreText-based font from a TTF/TTC in memory.
    pub fn init(lib: font.Library, source: [:0]const u8, size: font.face.DesiredSize) !Face {
        _ = lib;

        const data = try macos.foundation.Data.createWithBytesNoCopy(source);
        defer data.release();

        const arr = macos.text.createFontDescriptorsFromData(data) orelse
            return error.FontInitFailure;
        defer arr.release();

        const desc = arr.getValueAtIndex(macos.text.FontDescriptor, 0);
        const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
        defer ct_font.release();

        return try initFontCopy(ct_font, size);
    }

    /// Initialize a CoreText-based face from another initialized font face
    /// but with a new size. This is often how CoreText fonts are initialized
    /// because the font is loaded at a default size during discovery, and then
    /// adjusted to the final size for final load.
    pub fn initFontCopy(base: *macos.text.Font, size: font.face.DesiredSize) !Face {
        // Create a copy. The copyWithAttributes docs say the size is in points,
        // but we need to scale the points by the DPI and to do that we use our
        // function called "pixels".
        const ct_font = try base.copyWithAttributes(@floatFromInt(size.pixels()), null);
        errdefer ct_font.release();

        var hb_font = try harfbuzz.coretext.createFont(ct_font);
        errdefer hb_font.destroy();

        const traits = ct_font.getSymbolicTraits();

        return Face{
            .font = ct_font,
            .hb_font = hb_font,
            .presentation = if (traits.color_glyphs) .emoji else .text,
            .metrics = try calcMetrics(ct_font),
        };
    }

    pub fn deinit(self: *Face) void {
        self.font.release();
        self.hb_font.destroy();
        self.* = undefined;
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, size: font.face.DesiredSize) !void {
        // We just create a copy and replace ourself
        const face = try initFontCopy(self.font, size);
        self.deinit();
        self.* = face;
    }

    /// Returns the glyph index for the given Unicode code point. If this
    /// face doesn't support this glyph, null is returned.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        // Turn UTF-32 into UTF-16 for CT API
        var unichars: [2]u16 = undefined;
        const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
        const len: usize = if (pair) 2 else 1;

        // Get our glyphs
        var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
        if (!self.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]))
            return null;

        // We can have pairs due to chars like emoji but we expect all of them
        // to decode down into exactly one glyph ID.
        if (pair) assert(glyphs[1] == 0);

        return @intCast(glyphs[0]);
    }

    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        max_height: ?u16,
    ) !font.Glyph {
        _ = max_height;

        var glyphs = [_]macos.graphics.Glyph{@intCast(glyph_index)};

        // Get the bounding rect for rendering this glyph.
        const rect = self.font.getBoundingRectForGlyphs(.horizontal, &glyphs, null);

        // The x/y that we render the glyph at. The Y value has to be flipped
        // because our coordinates in 3D space are (0, 0) bottom left with
        // +y being up.
        const render_x = @floor(rect.origin.x);
        const render_y = @ceil(-rect.origin.y);

        // The ascent is the amount of pixels above the baseline this glyph
        // is rendered. The ascent can be calculated by adding the full
        // glyph height to the origin.
        const glyph_ascent = @ceil(rect.size.height + rect.origin.y);

        // The glyph height is basically rect.size.height but we do the
        // ascent plus the descent because both are rounded elements that
        // will make us more accurate.
        const height: u32 = @intFromFloat(glyph_ascent + render_y);

        // The glyph width is our advertised bounding with plus the rounding
        // difference from our rendering X.
        const width: u32 = @intFromFloat(@ceil(rect.size.width + (rect.origin.x - render_x)));

        // This bitmap is blank. I've seen it happen in a font, I don't know why.
        // If it is empty, we just return a valid glyph struct that does nothing.
        if (width == 0 or height == 0) return font.Glyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .atlas_x = 0,
            .atlas_y = 0,
            .advance_x = 0,
        };

        // Settings that are specific to if we are rendering text or emoji.
        const color: struct {
            color: bool,
            depth: u32,
            space: *macos.graphics.ColorSpace,
            context_opts: c_uint,
        } = if (self.presentation == .text) .{
            .color = false,
            .depth = 1,
            .space = try macos.graphics.ColorSpace.createDeviceGray(),
            .context_opts = @intFromEnum(macos.graphics.BitmapInfo.alpha_mask) &
                @intFromEnum(macos.graphics.ImageAlphaInfo.none),
        } else .{
            .color = true,
            .depth = 4,
            .space = try macos.graphics.ColorSpace.createDeviceRGB(),
            .context_opts = @intFromEnum(macos.graphics.BitmapInfo.byte_order_32_little) |
                @intFromEnum(macos.graphics.ImageAlphaInfo.premultiplied_first),
        };
        defer color.space.release();

        // This is just a safety check.
        if (atlas.format.depth() != color.depth) {
            log.warn("font atlas color depth doesn't equal font color depth atlas={} font={}", .{
                atlas.format.depth(),
                color.depth,
            });
            return error.InvalidAtlasFormat;
        }

        // Our buffer for rendering
        // TODO(perf): cache this buffer
        var buf = try alloc.alloc(u8, width * height * color.depth);
        defer alloc.free(buf);
        @memset(buf, 0);

        const ctx = try macos.graphics.BitmapContext.create(
            buf,
            width,
            height,
            8,
            width * color.depth,
            color.space,
            color.context_opts,
        );
        defer ctx.release();

        // Perform an initial fill. This ensures that we don't have any
        // uninitialized pixels in the bitmap.
        if (color.color)
            ctx.setRGBFillColor(1, 1, 1, 0)
        else
            ctx.setGrayFillColor(0, 0);
        ctx.fillRect(.{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
            },
        });

        ctx.setAllowsFontSmoothing(true);
        ctx.setShouldSmoothFonts(false); // The amadeus "enthicken"
        ctx.setAllowsFontSubpixelQuantization(true);
        ctx.setShouldSubpixelQuantizeFonts(true);
        ctx.setAllowsFontSubpixelPositioning(true);
        ctx.setShouldSubpixelPositionFonts(true);
        ctx.setAllowsAntialiasing(true);
        ctx.setShouldAntialias(true);

        // Set our color for drawing
        if (color.color) {
            ctx.setRGBFillColor(1, 1, 1, 1);
            ctx.setRGBStrokeColor(1, 1, 1, 1);
        } else {
            ctx.setGrayFillColor(1, 1);
            ctx.setGrayStrokeColor(1, 1);
        }

        // We want to render the glyphs at (0,0), but the glyphs themselves
        // are offset by bearings, so we have to undo those bearings in order
        // to get them to 0,0. We also add the padding so that they render
        // slightly off the edge of the bitmap.
        self.font.drawGlyphs(&glyphs, &.{
            .{
                .x = -1 * render_x,
                .y = render_y,
            },
        }, ctx);

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
        atlas.set(region, buf);

        const offset_y: i32 = offset_y: {
            // Our Y coordinate in 3D is (0, 0) bottom left, +y is UP.
            // We need to calculate our baseline from the bottom of a cell.
            const baseline_from_bottom = self.metrics.cell_height - self.metrics.cell_baseline;

            // Next we offset our baseline by the bearing in the font. We
            // ADD here because CoreText y is UP.
            const baseline_with_offset = baseline_from_bottom + glyph_ascent;

            break :offset_y @intFromFloat(@ceil(baseline_with_offset));
        };

        // log.warn("renderGlyph rect={} width={} height={} render_x={} render_y={} offset_y={} ascent={} cell_height={} cell_baseline={}", .{
        //     rect,
        //     width,
        //     height,
        //     render_x,
        //     render_y,
        //     offset_y,
        //     glyph_ascent,
        //     self.metrics.cell_height,
        //     self.metrics.cell_baseline,
        // });

        return .{
            .width = width,
            .height = height,
            .offset_x = @intFromFloat(render_x),
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,

            // This is not used, so we don't bother calculating it. If we
            // ever need it, we can calculate it using getAdvancesForGlyph.
            .advance_x = 0,
        };
    }

    fn calcMetrics(ct_font: *macos.text.Font) !font.face.Metrics {
        // Cell width is calculated by calculating the widest width of the
        // visible ASCII characters. Usually 'M' is widest but we just take
        // whatever is widest.
        const cell_width: f32 = cell_width: {
            // Build a comptime array of all the ASCII chars
            const unichars = comptime unichars: {
                const len = 127 - 32;
                var result: [len]u16 = undefined;
                var i: u16 = 32;
                while (i < 127) : (i += 1) {
                    result[i - 32] = i;
                }

                break :unichars result;
            };

            // Get our glyph IDs for the ASCII chars
            var glyphs: [unichars.len]macos.graphics.Glyph = undefined;
            _ = ct_font.getGlyphsForCharacters(&unichars, &glyphs);

            // Get all our advances
            var advances: [unichars.len]macos.graphics.Size = undefined;
            _ = ct_font.getAdvancesForGlyphs(.horizontal, &glyphs, &advances);

            // Find the maximum advance
            var max: f64 = 0;
            var i: usize = 0;
            while (i < advances.len) : (i += 1) {
                max = @max(advances[i].width, max);
            }

            break :cell_width @floatCast(max);
        };

        // Calculate the cell height by using CoreText's layout engine
        // to tell us after laying out some text. This is inspired by Kitty's
        // approach. Previously we were using descent/ascent math and it wasn't
        // quite the same with CoreText and I never figured out why.
        const layout_metrics: struct {
            height: f32,
            ascent: f32,
        } = metrics: {
            const unit = "AQWMH_gyl " ** 100;

            // Setup our string we'll layout. We just stylize a string of
            // ASCII characters to setup the letters.
            const string = try macos.foundation.MutableAttributedString.create(unit.len);
            defer string.release();
            const rep = try macos.foundation.String.createWithBytes(unit, .utf8, false);
            defer rep.release();
            string.replaceString(macos.foundation.Range.init(0, 0), rep);
            string.setAttribute(
                macos.foundation.Range.init(0, unit.len),
                macos.text.StringAttribute.font,
                ct_font,
            );

            // Create our framesetter with our string. This is used to
            // emit "frames" for the layout.
            const fs = try macos.text.Framesetter.createWithAttributedString(@ptrCast(string));
            defer fs.release();

            // Create a rectangle to fit all of this and create a frame of it.
            // The rectangle needs to fit all of our text so we use some
            // heuristics based on cell_width to calculate it. We are
            // VERY generous with our rect here because the text must fit.
            const path_rect = rect: {
                // The cell width at this point is valid, so let's make it
                // fit 50 characters wide.
                const width = cell_width * 50;

                // We are trying to calculate height so we don't know how
                // high to make our frame. Well-behaved fonts will probably
                // not have a height greater than 4x the width, so let's just
                // generously use that metric to ensure we fit the frame.
                const big_cell_height = cell_width * 4;

                // If we are fitting about ~50 characters per row, we need
                // unit.len / 50 rows to fit all of our text.
                const rows = (unit.len / 50) * 2;

                // Our final height is the number of rows times our generous height.
                const height = rows * big_cell_height;

                break :rect macos.graphics.Rect.init(10, 10, width, height);
            };

            const path = try macos.graphics.MutablePath.create();
            path.addRect(null, path_rect);
            defer path.release();
            const frame = try fs.createFrame(
                macos.foundation.Range.init(0, 0),
                @ptrCast(path),
                null,
            );
            defer frame.release();

            // Use our text layout from earlier to measure the difference
            // between the lines.
            var points: [2]macos.graphics.Point = undefined;
            frame.getLineOrigins(macos.foundation.Range.init(0, 1), points[0..]);
            frame.getLineOrigins(macos.foundation.Range.init(1, 1), points[1..]);

            const lines = frame.getLines();
            const line = lines.getValueAtIndex(macos.text.Line, 0);

            // NOTE(mitchellh): For some reason, CTLineGetBoundsWithOptions
            // returns garbage and I can't figure out why... so we use the
            // raw ascender.
            const bounds = line.getBoundsWithOptions(.{ .exclude_leading = true });
            const bounds_ascent = bounds.size.height + bounds.origin.y;
            const baseline = @floor(bounds_ascent + 0.5);

            // This is an alternate approach to the above to calculate the
            // baseline by simply using the ascender. Using this approach led
            // to less accurate results, but I'm leaving it here for reference.
            // var ascent: f64 = 0;
            // var descent: f64 = 0;
            // var leading: f64 = 0;
            // _ = line.getTypographicBounds(&ascent, &descent, &leading);
            //std.log.warn("ascent={} descent={} leading={}", .{ ascent, descent, leading });

            break :metrics .{
                .height = @floatCast(points[0].y - points[1].y),
                .ascent = @floatCast(baseline),
            };
        };

        // All of these metrics are based on our layout above.
        const cell_height = layout_metrics.height;
        const cell_baseline = layout_metrics.ascent;
        const underline_position = @ceil(layout_metrics.ascent -
            @as(f32, @floatCast(ct_font.getUnderlinePosition())));
        const underline_thickness = @ceil(@as(f32, @floatCast(ct_font.getUnderlineThickness())));
        const strikethrough_position = cell_baseline * 0.6;
        const strikethrough_thickness = underline_thickness;

        // Note: is this useful?
        // const units_per_em = ct_font.getUnitsPerEm();
        // const units_per_point = @intToFloat(f64, units_per_em) / ct_font.getSize();

        std.log.warn("font size size={d}", .{ct_font.getSize()});
        std.log.warn("font metrics width={d}, height={d} baseline={d} underline_pos={d} underline_thickness={d}", .{
            cell_width,
            cell_height,
            cell_baseline,
            underline_position,
            underline_thickness,
        });
        return font.face.Metrics{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .cell_baseline = cell_baseline,
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
            .strikethrough_position = strikethrough_position,
            .strikethrough_thickness = strikethrough_thickness,
        };
    }
};

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    const name = try macos.foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .points = 12 });
    defer face.deinit();

    try testing.expectEqual(font.Presentation.text, face.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?, null);
    }
}

test "emoji" {
    const testing = std.testing;

    const name = try macos.foundation.String.createWithBytes("Apple Color Emoji", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .points = 18 });
    defer face.deinit();

    // Presentation
    try testing.expectEqual(font.Presentation.emoji, face.presentation);

    // Glyph index check
    try testing.expect(face.glyphIndex('🥸') != null);
}

test "in-memory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("../test.zig").fontRegular;

    var atlas = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    var lib = try font.Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .points = 12 });
    defer face.deinit();

    try testing.expectEqual(font.Presentation.text, face.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?, null);
    }
}
