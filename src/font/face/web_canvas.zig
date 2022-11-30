const std = @import("std");
const builtin = @import("builtin");
const freetype = @import("freetype");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Glyph = font.Glyph;
const Library = font.Library;
const Presentation = font.Presentation;
const convert = @import("freetype_convert.zig");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    /// The presentation for this font. This is a heuristic since fonts don't have
    /// a way to declare this. We just assume a font with color is an emoji font.
    presentation: Presentation,

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.face.Metrics,
};
