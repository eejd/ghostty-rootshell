const builtin = @import("builtin");
const options = @import("build_options");
const std = @import("std");
const glfw = @import("glfw");

const App = @import("App.zig");
const cli_args = @import("cli_args.zig");
const tracy = @import("tracy/tracy.zig");
const Config = @import("config.zig").Config;

const log = std.log.scoped(.main);

pub fn main() !void {
    const gpa = gpa: {
        // Use the libc allocator if it is available beacuse it is WAY
        // faster than GPA. We only do this in release modes so that we
        // can get easy memory leak detection in debug modes.
        if (builtin.link_libc) {
            switch (builtin.mode) {
                .ReleaseSafe, .ReleaseFast => break :gpa std.heap.c_allocator,
                else => {},
            }
        }

        // We don't ever deinit our GPA because the process cleanup will
        // clean it up. This defer isn't in the right location anyways because
        // it'll deinit on return from blk.
        // defer _ = general_purpose_allocator.deinit();

        var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
        break :gpa general_purpose_allocator.allocator();
    };

    // If we're tracing, then wrap memory so we can trace allocations
    const alloc = if (!tracy.enabled) gpa else tracy.allocator(gpa, null).allocator();

    // Parse the config from the CLI args
    var config = config: {
        var result: Config = .{};
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try cli_args.parse(Config, alloc, &result, &iter);
        break :config result;
    };
    defer config.deinit();
    log.info("config={}", .{config});

    // We want to log all our errors
    glfw.setErrorCallback(glfwErrorCallback);

    // Initialize glfw
    try glfw.init(.{});
    defer glfw.terminate();

    // Run our app
    var app = try App.init(alloc, &config);
    defer app.deinit();
    try app.run();
}

// Required by tracy/tracy.zig to enable/disable tracy support.
pub fn tracy_enabled() bool {
    return options.tracy_enabled;
}

fn glfwErrorCallback(code: glfw.Error, desc: [:0]const u8) void {
    log.warn("glfw error={} message={s}", .{ code, desc });
}

test {
    _ = @import("Atlas.zig");
    _ = @import("Grid.zig");
    _ = @import("Pty.zig");
    _ = @import("Command.zig");
    _ = @import("TempDir.zig");
    _ = @import("font/font.zig");
    _ = @import("terminal/Terminal.zig");

    // Libraries
    _ = @import("segmented_pool.zig");
    _ = @import("libuv/main.zig");
    _ = @import("terminal/main.zig");

    // TODO
    _ = @import("config.zig");
    _ = @import("cli_args.zig");
}
