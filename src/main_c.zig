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
const options = @import("build_options");
const fontconfig = @import("fontconfig");
const harfbuzz = @import("harfbuzz");
const renderer = @import("renderer.zig");
const tracy = @import("tracy");
const xev = @import("xev");
const internal_os = @import("os/main.zig");
const main = @import("main.zig");

/// Global options so we can log. This is identical to main.
pub const std_options = main.std_options;

pub usingnamespace @import("config.zig").CAPI;

/// Initialize ghostty global state. It is possible to have more than
/// one global state but it has zero practical benefit.
export fn ghostty_init() ?*Ghostty {
    assert(builtin.link_libc);
    const alloc = std.heap.c_allocator;
    const g = alloc.create(Ghostty) catch return null;
    Ghostty.init(g);
    return g;
}

/// This represents the global process state. There should only
/// be one of these at any given moment. This is extracted into a dedicated
/// struct because it is reused by main and the static C lib.
///
/// init should be one of the first things ever called when using Ghostty.
pub const Ghostty = struct {
    const GPA = std.heap.GeneralPurposeAllocator(.{});

    gpa: ?GPA,
    alloc: std.mem.Allocator,

    pub fn init(self: *Ghostty) void {
        // Output some debug information right away
        std.log.info("dependency harfbuzz={s}", .{harfbuzz.versionString()});
        if (options.fontconfig) {
            std.log.info("dependency fontconfig={d}", .{fontconfig.version()});
        }
        std.log.info("renderer={}", .{renderer.Renderer});
        std.log.info("libxev backend={}", .{xev.backend});

        // First things first, we fix our file descriptors
        internal_os.fixMaxFiles();

        // We need to make sure the process locale is set properly. Locale
        // affects a lot of behaviors in a shell.
        internal_os.ensureLocale();

        // Initialize ourself to nothing so we don't have any extra state.
        self.* = .{
            .gpa = null,
            .alloc = undefined,
        };
        errdefer self.deinit();

        self.gpa = gpa: {
            // Use the libc allocator if it is available beacuse it is WAY
            // faster than GPA. We only do this in release modes so that we
            // can get easy memory leak detection in debug modes.
            if (builtin.link_libc) {
                if (switch (builtin.mode) {
                    .ReleaseSafe, .ReleaseFast => true,

                    // We also use it if we can detect we're running under
                    // Valgrind since Valgrind only instruments the C allocator
                    else => std.valgrind.runningOnValgrind() > 0,
                }) break :gpa null;
            }

            break :gpa GPA{};
        };

        self.alloc = alloc: {
            const base = if (self.gpa) |*value|
                value.allocator()
            else if (builtin.link_libc)
                std.heap.c_allocator
            else
                unreachable;

            // If we're tracing, wrap the allocator
            if (!tracy.enabled) break :alloc base;
            var tracy_alloc = tracy.allocator(base, null);
            break :alloc tracy_alloc.allocator();
        };
    }

    pub fn deinit(self: *Ghostty) void {
        if (self.gpa) |*value| {
            // We want to ensure that we deinit the GPA because this is
            // the point at which it will output if there were safety violations.
            _ = value.deinit();
        }
    }
};
