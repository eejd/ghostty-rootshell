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

/// The loaded face (once loaded).
face: ?Face = null,

/// Fontconfig
fc: if (options.fontconfig) Fontconfig else void = undefined,

/// Fontconfig specific data. This is only present if building with fontconfig.
pub const Fontconfig = struct {
    pattern: *fontconfig.Pattern,
    charset: *fontconfig.CharSet,
    langset: *fontconfig.LangSet,
};

pub fn deinit(self: *DeferredFace) void {
    if (self.face) |*face| face.deinit();

    self.* = undefined;
}

/// Returns true if the face has been loaded.
pub inline fn loaded(self: DeferredFace) bool {
    return self.face != null;
}
