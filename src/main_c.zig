// This is the main file for the C API. The C API is used to embed Ghostty
// within other applications. Depending on the build settings some APIs
// may not be available (i.e. embedding into macOS exposes various Metal
// support).
const std = @import("std");
const builtin = @import("builtin");

// We're just testing right now.
export fn ghostty_hello() u64 {
    return 42;
}
