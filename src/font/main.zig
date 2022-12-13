const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Atlas = @import("Atlas.zig");
pub const discovery = @import("discovery.zig");
pub const face = @import("face.zig");
pub const DeferredFace = @import("DeferredFace.zig");
pub const Face = face.Face;
pub const Group = @import("Group.zig");
pub const GroupCache = @import("GroupCache.zig");
pub const Glyph = @import("Glyph.zig");
pub const shape = @import("shape.zig");
pub const Shaper = shape.Shaper;
pub const sprite = @import("sprite.zig");
pub const Sprite = sprite.Sprite;
pub const Descriptor = discovery.Descriptor;
pub const Discover = discovery.Discover;
pub usingnamespace @import("library.zig");

/// If we're targeting wasm then we export some wasm APIs.
pub usingnamespace if (builtin.target.isWasm()) struct {
    pub usingnamespace Atlas.Wasm;
    pub usingnamespace DeferredFace.Wasm;
    pub usingnamespace Group.Wasm;
    pub usingnamespace GroupCache.Wasm;
    pub usingnamespace face.web_canvas.Wasm;
    pub usingnamespace shape.web_canvas.Wasm;
} else struct {};

/// Build options
pub const options: struct {
    backend: Backend,
} = .{
    .backend = Backend.default(),
};

pub const Backend = enum {
    /// FreeType for font rendering with no font discovery enabled.
    freetype,

    /// Fontconfig for font discovery and FreeType for font rendering.
    fontconfig_freetype,

    /// CoreText for both font discovery for rendering (macOS).
    coretext,

    /// CoreText for font discovery and FreeType for rendering (macOS).
    coretext_freetype,

    /// Use the browser font system and the Canvas API (wasm). This limits
    /// the available fonts to browser fonts (anything Canvas natively
    /// supports).
    web_canvas,

    /// Returns the default backend for a build environment. This is
    /// meant to be called at comptime.
    pub fn default() Backend {
        // Wasm only supports browser at the moment.
        if (builtin.target.isWasm()) return .web_canvas;

        return if (build_options.coretext)
            .coretext
        else if (build_options.fontconfig)
            .fontconfig_freetype
        else
            .freetype;
    }

    /// Helper that just returns true if we should be using freetype. This
    /// is used for tests.
    pub fn freetype(self: Backend) bool {
        return switch (self) {
            .freetype, .fontconfig_freetype => true,
            .coretext, .web_canvas => false,
        };
    }

    test "default can run at comptime" {
        _ = comptime default();
    }
};

/// The styles that a family can take.
pub const Style = enum(u3) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

/// The presentation for a an emoji.
pub const Presentation = enum(u1) {
    text = 0, // U+FE0E
    emoji = 1, // U+FEOF
};

/// A FontIndex that can be used to use the sprite font directly.
pub const sprite_index = Group.FontIndex.initSpecial(.sprite);

test {
    // For non-wasm we want to test everything we can
    if (!comptime builtin.target.isWasm()) {
        @import("std").testing.refAllDecls(@This());
        return;
    }

    _ = Atlas;
}
