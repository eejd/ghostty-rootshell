const builtin = @import("builtin");
const options = @import("main.zig").options;
const harfbuzz = @import("shaper/harfbuzz.zig");

/// Shaper implementation for our compile options.
pub const Shaper = switch (options.backend) {
    .freetype,
    .fontconfig_freetype,
    .coretext_freetype,
    .coretext,
    => harfbuzz.Shaper,

    .web_canvas => harfbuzz.Shaper,
};
