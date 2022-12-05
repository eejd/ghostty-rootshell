const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const js = @import("zig-js");
const font = @import("../main.zig");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    /// The web canvas face makes use of an allocator when interacting
    /// with the JS environment.
    alloc: Allocator,

    /// The CSS "font" attribute, excluding size.
    font_str: []const u8,

    /// The size we currently have set.
    size: font.face.DesiredSize,

    /// The presentation for this font. This is a heuristic since fonts don't have
    /// a way to declare this. We just assume a font with color is an emoji font.
    presentation: font.Presentation,

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.face.Metrics,

    /// The canvas element that we will reuse to render glyphs
    canvas: js.Object,

    /// Initialize a web canvas font with a "raw" value. The "raw" value can
    /// be any valid value for a CSS "font" property EXCLUDING the size. The
    /// size is always added via the `size` parameter.
    ///
    /// The raw value is copied so the caller can free it after it is gone.
    pub fn initNamed(
        alloc: Allocator,
        raw: []const u8,
        size: font.face.DesiredSize,
    ) !Face {
        // Copy our font string because we're going to have to reuse it.
        const font_str = try alloc.dupe(u8, raw);
        errdefer alloc.free(font_str);

        // Create our canvas that we're going to continue to reuse.
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const canvas = try doc.call(js.Object, "createElement", .{js.string("canvas")});
        errdefer canvas.deinit();

        var result = Face{
            .alloc = alloc,
            .font_str = font_str,
            .size = size,
            // TODO: figure out how we're going to do emoji with web canvas
            .presentation = .text,

            .canvas = canvas,

            // We're going to calculate these right after initialization.
            .metrics = undefined,
        };
        try result.calcMetrics();

        log.debug("face initialized: {s}", .{raw});
        return result;
    }

    pub fn deinit(self: *Face) void {
        self.alloc.free(self.font_str);
        self.canvas.deinit();
        self.* = undefined;
    }

    /// Calculate the metrics associated with a given face.
    fn calcMetrics(self: *Face) !void {
        // This will return the same context on subsequent calls so it
        // is important to reset it.
        const ctx = try self.canvas.call(js.Object, "getContext", .{js.string("2d")});
        defer ctx.deinit();

        // Set our context font
        var font_val = try std.fmt.allocPrint(
            self.alloc,
            "{d}px {s}",
            .{ self.size.points, self.font_str },
        );
        defer self.alloc.free(font_val);
        try ctx.set("font", js.string(font_val));

        // If the font property didn't change, then the font set didn't work.
        // We do this check because it is very easy to put an invalid font
        // in and this at least makes it show up in the logs.
        {
            const check = try ctx.getAlloc(js.String, self.alloc, "font");
            defer self.alloc.free(check);
            if (!std.mem.eql(u8, font_val, check)) {
                log.warn("canvas font didn't set, fonts may be broken, expected={s} got={s}", .{
                    font_val,
                    check,
                });
            }
        }

        // Cell width is the width of our M text
        const cell_width: f32 = cell_width: {
            const metrics = try ctx.call(js.Object, "measureText", .{js.string("M")});
            defer metrics.deinit();
            break :cell_width try metrics.get(f32, "actualBoundingBoxRight");
        };

        // To get the cell height we render a high and low character and get
        // the total of the ascent and descent. This should equal our
        // pixel height but this is a more surefire way to get it.
        const height_metrics = try ctx.call(js.Object, "measureText", .{js.string("M_")});
        defer height_metrics.deinit();
        const asc = try height_metrics.get(f32, "actualBoundingBoxAscent");
        const desc = try height_metrics.get(f32, "actualBoundingBoxDescent");
        const cell_height = asc + desc;
        const cell_baseline = desc;

        // There isn't a declared underline position for canvas measurements
        // so we just go 1 under the cell height to match freetype logic
        // at this time (our freetype logic).
        const underline_position = cell_height - 1;
        const underline_thickness: f32 = 1;

        self.metrics = .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .cell_baseline = cell_baseline,
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
            .strikethrough_position = underline_position,
            .strikethrough_thickness = underline_thickness,
        };

        log.debug("metrics font={s} value={}", .{ font_val, self.metrics });
    }
};

/// The wasm-compatible API.
pub const Wasm = struct {
    const wasm = @import("../../os/wasm.zig");
    const alloc = wasm.alloc;

    export fn face_new(ptr: [*]const u8, len: usize, pts: u16) ?*Face {
        return face_new_(ptr, len, pts) catch null;
    }

    fn face_new_(ptr: [*]const u8, len: usize, pts: u16) !*Face {
        var face = try Face.initNamed(alloc, ptr[0..len], .{ .points = pts });
        errdefer face.deinit();

        var result = try alloc.create(Face);
        errdefer alloc.destroy(result);
        result.* = face;
        return result;
    }

    export fn face_free(ptr: ?*Face) void {
        if (ptr) |v| {
            v.deinit();
            alloc.destroy(v);
        }
    }
};
