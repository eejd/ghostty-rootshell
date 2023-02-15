// This is the main file for the C API. The C API is used to embed Ghostty
// within other applications. Depending on the build settings some APIs
// may not be available (i.e. embedding into macOS exposes various Metal
// support).
//
// This currently isn't supported as a general purpose embedding API.
// This is currently used only to embed ghostty within a macOS app. However,
// it could be expanded to be general purpose in the future.
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const main = @import("main.zig");

/// Global options so we can log. This is identical to main.
pub const std_options = main.std_options;

pub usingnamespace @import("config.zig").CAPI;

/// Initialize ghostty global state. It is possible to have more than
/// one global state but it has zero practical benefit.
export fn ghostty_init() c_int {
    assert(builtin.link_libc);
    main.state.init();
    return 0;
}
