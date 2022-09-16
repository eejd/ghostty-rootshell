const std = @import("std");
const assert = std.debug.assert;
const fontconfig = @import("fontconfig");

const log = std.log.named(.discovery);

/// Descriptor is used to search for fonts. The only required field
/// is "family". The rest are ignored unless they're set to a non-zero value.
pub const Descriptor = struct {
    /// Font family to search for. This can be a fully qualified font
    /// name such as "Fira Code", "monospace", "serif", etc. Memory is
    /// owned by the caller and should be freed when this descriptor
    /// is no longer in use. The discovery structs will never store the
    /// descriptor.
    ///
    /// On systems that use fontconfig (Linux), this can be a full
    /// fontconfig pattern, such as "Fira Code-14:bold".
    family: [:0]const u8,

    /// Font size in points that the font should support.
    size: u16 = 0,

    /// True if we want to search specifically for a font that supports
    /// bold, italic, or both.
    bold: bool = false,
    italic: bool = false,

    /// Convert to Fontconfig pattern to use for lookup. The pattern does
    /// not have defaults filled/substituted (Fontconfig thing) so callers
    /// must still do this.
    pub fn toFcPattern(self: Descriptor) *fontconfig.Pattern {
        const pat = fontconfig.Pattern.create();
        assert(pat.add(.family, .{ .string = self.family }, false));
        if (self.size > 0) assert(pat.add(.size, .{ .integer = self.size }, false));
        if (self.bold) assert(pat.add(
            .weight,
            .{ .integer = @enumToInt(fontconfig.Weight.bold) },
            false,
        ));
        if (self.italic) assert(pat.add(
            .slant,
            .{ .integer = @enumToInt(fontconfig.Slant.italic) },
            false,
        ));

        return pat;
    }
};

pub const Fontconfig = struct {
    fc_config: *fontconfig.Config,

    pub fn init() Fontconfig {
        // safe to call multiple times and concurrently
        _ = fontconfig.init();
        return .{ .fc_config = fontconfig.initLoadConfig() };
    }

    pub fn discover(self: *Fontconfig, desc: Descriptor) void {
        // Build our pattern that we'll search for
        const pat = desc.toFcPattern();
        defer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();

        // Search
        const res = self.fc_config.fontSort(pat, true, null);
        defer res.fs.destroy();
    }
};

test {
    defer fontconfig.fini();
    var fc = Fontconfig.init();

    fc.discover(.{ .family = "monospace" });
}
