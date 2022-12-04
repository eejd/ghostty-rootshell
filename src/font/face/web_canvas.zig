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

        log.debug("face initialized: {s}", .{raw});

        return Face{
            .alloc = alloc,
            .font_str = font_str,
            .size = size,

            .canvas = canvas,

            // TODO: real metrics
            .metrics = undefined,

            // TODO: figure out how we're going to do emoji with web canvas
            .presentation = .text,
        };
    }

    pub fn deinit(self: *Face) void {
        self.alloc.free(self.font_str);
        self.canvas.deinit();
        self.* = undefined;
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
