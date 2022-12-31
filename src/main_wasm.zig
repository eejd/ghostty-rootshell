// This is the main file for the WASM module. The WASM module has to
// export a C ABI compatible API.
const std = @import("std");
const builtin = @import("builtin");

pub usingnamespace @import("os/wasm.zig");
pub usingnamespace @import("os/wasm/log.zig");
pub usingnamespace @import("font/main.zig");
pub usingnamespace @import("terminal/main.zig");
pub usingnamespace @import("config.zig").Wasm;

// Set our log level. We try to get as much logging as possible but in
// ReleaseSmall mode where we're optimizing for space, we elevate the
// log level.
pub const log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSmall => .warn,
    else => .info,
};
