//! A deferred face represents a single font face with all the information
//! necessary to load it, but defers loading the full face until it is
//! needed.
//!
//! This allows us to have many fallback fonts to look for glyphs, but
//! only load them if they're really needed.
const DeferredFace = @This();

const std = @import("std");
const assert = std.debug.assert;
const fontconfig = @import("fontconfig");
const options = @import("main.zig").options;
const Face = @import("main.zig").Face;
const Presentation = @import("main.zig").Presentation;

/// The loaded face (once loaded).
face: ?Face = null,

/// Fontconfig
fc: if (options.fontconfig) ?Fontconfig else void = if (options.fontconfig) null else {},

/// Fontconfig specific data. This is only present if building with fontconfig.
pub const Fontconfig = struct {
    pattern: *fontconfig.Pattern,
    charset: *const fontconfig.CharSet,
    langset: *const fontconfig.LangSet,

    pub fn deinit(self: *Fontconfig) void {
        self.pattern.destroy();
        self.* = undefined;
    }
};

pub fn deinit(self: *DeferredFace) void {
    if (self.face) |*face| face.deinit();
    if (options.fontconfig) if (self.fc) |*fc| fc.deinit();
    self.* = undefined;
}

/// Returns true if the face has been loaded.
pub inline fn loaded(self: DeferredFace) bool {
    return self.face != null;
}

/// Returns true if this face can satisfy the given codepoint and
/// presentation. If presentation is null, then it just checks if the
/// codepoint is present at all.
///
/// This should not require the face to be loaded IF we're using a
/// discovery mechanism (i.e. fontconfig). If no discovery is used,
/// the face is always expected to be loaded.
pub fn hasCodepoint(self: DeferredFace, cp: u32, p: ?Presentation) bool {
    // If we have the face, use the face.
    if (self.face) |face| {
        if (p) |desired| if (face.presentation != desired) return false;
        return face.glyphIndex(cp) != null;
    }

    // If we are using fontconfig, use the fontconfig metadata to
    // avoid loading the face.
    if (options.fontconfig) {
        if (self.fc) |fc| {
            // Check if char exists
            if (!fc.charset.hasChar(cp)) return false;

            // If we have a presentation, check it matches
            if (p) |desired| {
                const emoji_lang = "und-zsye";
                const actual: Presentation = if (fc.langset.hasLang(emoji_lang))
                    .emoji
                else
                    .text;

                return desired == actual;
            }

            return true;
        }
    }

    // This is unreachable because discovery mechanisms terminate, and
    // if we're not using a discovery mechanism, the face MUST be loaded.
    unreachable;
}
