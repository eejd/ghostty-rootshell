pub const Face = @import("Face.zig");
pub const Family = @import("Family.zig");
pub const Glyph = @import("Glyph.zig");

/// Embedded fonts (for now)
pub const fontRegular = @import("test.zig").fontRegular;
pub const fontBold = @import("test.zig").fontBold;

/// The styles that a family can take.
pub const Style = enum {
    regular,
    bold,
    italic,
    bold_italic,
};

test {
    _ = Face;
    _ = Family;
    _ = Glyph;
}
