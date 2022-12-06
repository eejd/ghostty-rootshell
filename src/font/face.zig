const builtin = @import("builtin");
const options = @import("main.zig").options;
const freetype = @import("face/freetype.zig");
const coretext = @import("face/coretext.zig");
pub const web_canvas = @import("face/web_canvas.zig");

/// Face implementation for the compile options.
pub const Face = switch (options.backend) {
    .freetype,
    .fontconfig_freetype,
    .coretext_freetype,
    => freetype.Face,

    .coretext => coretext.Face,
    .web_canvas => web_canvas.Face,
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

/// Metrics associated with the font that are useful for renderers to know.
pub const Metrics = struct {
    /// Recommended cell width and height for a monospace grid using this font.
    cell_width: f32,
    cell_height: f32,

    /// For monospace grids, the recommended y-value from the bottom to set
    /// the baseline for font rendering. This is chosen so that things such
    /// as the bottom of a "g" or "y" do not drop below the cell.
    cell_baseline: f32,

    /// The position of the underline from the top of the cell and the
    /// thickness in pixels.
    underline_position: f32,
    underline_thickness: f32,

    /// The position and thickness of a strikethrough. Same units/style
    /// as the underline fields.
    strikethrough_position: f32,
    strikethrough_thickness: f32,
};

pub const Foo = if (options.backend == .coretext) coretext.Face else void;

test {
    @import("std").testing.refAllDecls(@This());
}
