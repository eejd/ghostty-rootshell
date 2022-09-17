const std = @import("std");
const assert = std.debug.assert;
const fontconfig = @import("fontconfig");
const DeferredFace = @import("main.zig").DeferredFace;

const log = std.log.named(.discovery);

pub const Error = error{
    FontConfigFailed,
};

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

    /// Font size in points that the font should support. For conversion
    /// to pixels, we will use 72 DPI for Mac and 96 DPI for everything else.
    /// (If pixel conversion is necessary, i.e. emoji fonts)
    size: u16,

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
        return .{ .fc_config = fontconfig.initLoadConfigAndFonts() };
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(self: *Fontconfig, desc: Descriptor) !DiscoverIterator {
        // Build our pattern that we'll search for
        const pat = desc.toFcPattern();
        errdefer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();

        // Search
        const res = self.fc_config.fontSort(pat, true, null);
        if (res.result != .match) return Error.FontConfigFailed;
        errdefer res.fs.destroy();

        return DiscoverIterator{
            .config = self.fc_config,
            .pattern = pat,
            .set = res.fs,
            .fonts = res.fs.fonts(),
            .i = 0,
            .req_size = @floatToInt(u16, (try pat.get(.size, 0)).double),
        };
    }

    pub const DiscoverIterator = struct {
        config: *fontconfig.Config,
        pattern: *fontconfig.Pattern,
        set: *fontconfig.FontSet,
        fonts: []*fontconfig.Pattern,
        i: usize,
        req_size: u16,

        pub fn deinit(self: *DiscoverIterator) void {
            self.set.destroy();
            self.pattern.destroy();
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) fontconfig.Error!?DeferredFace {
            if (self.i >= self.fonts.len) return null;

            // Get the copied pattern from our fontset that has the
            // attributes configured for rendering.
            const font_pattern = try self.config.fontRenderPrepare(
                self.pattern,
                self.fonts[self.i],
            );
            errdefer font_pattern.destroy();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .face = null,
                .fc = .{
                    .pattern = font_pattern,
                    .charset = (try font_pattern.get(.charset, 0)).char_set,
                    .langset = (try font_pattern.get(.lang, 0)).lang_set,
                    .req_size = self.req_size,
                },
            };
        }
    };
};

test {
    const testing = std.testing;

    var fc = Fontconfig.init();
    var it = try fc.discover(.{ .family = "monospace", .size = 12 });
    defer it.deinit();
    while (try it.next()) |face| {
        try testing.expect(!face.loaded());
    }
}
