const builtin = @import("builtin");
const options = @import("main.zig").options;
const freetype = @import("face/freetype.zig");
const coretext = @import("face/coretext.zig");

/// Face implementation for the compile options.
pub const Face = switch (options.backend) {
    .fontconfig_freetype => freetype.Face,
    .coretext => freetype.Face,
    //.coretext => coretext.Face,
    else => unreachable,
};

/// If a DPI can't be calculated, this DPI is used. This is probably
/// wrong on modern devices so it is highly recommended you get the DPI
/// using whatever platform method you can.
pub const default_dpi = if (builtin.os.tag == .macos) 72 else 96;

/// The desired size for loading a font.
pub const DesiredSize = struct {
    // Desired size in points
    points: u16,

    // The DPI of the screen so we can convert points to pixels.
    xdpi: u16 = default_dpi,
    ydpi: u16 = default_dpi,

    // Converts points to pixels
    pub fn pixels(self: DesiredSize) u16 {
        // 1 point = 1/72 inch
        return (self.points * self.ydpi) / 72;
    }
};
