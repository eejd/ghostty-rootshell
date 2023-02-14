const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const glfw = @import("glfw");
const macos = @import("macos");
const xdg = @import("xdg.zig");

const App = @import("App.zig");
const cli_args = @import("cli_args.zig");
const Config = @import("config.zig").Config;
const Ghostty = @import("main_c.zig").Ghostty;

pub fn main() !void {
    var state: Ghostty = undefined;
    Ghostty.init(&state);
    defer state.deinit();
    const alloc = state.alloc;

    // Try reading our config
    var config = try Config.default(alloc);
    defer config.deinit();

    // If we have a configuration file in our home directory, parse that first.
    const cwd = std.fs.cwd();
    {
        const home_config_path = try xdg.config(alloc, .{ .subdir = "ghostty/config" });
        defer alloc.free(home_config_path);

        if (cwd.openFile(home_config_path, .{})) |file| {
            defer file.close();

            var buf_reader = std.io.bufferedReader(file.reader());
            var iter = cli_args.lineIterator(buf_reader.reader());
            try cli_args.parse(Config, alloc, &config, &iter);
        } else |err| switch (err) {
            error.FileNotFound => std.log.info(
                "homedir config not found, not loading path={s}",
                .{home_config_path},
            ),

            else => std.log.warn(
                "error reading homedir config file, not loading err={} path={s}",
                .{ err, home_config_path },
            ),
        }
    }

    // Parse the config from the CLI args
    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try cli_args.parse(Config, alloc, &config, &iter);
    }

    // Parse the config files that were added from our file and CLI args.
    // TODO(mitchellh): we should parse the files form the homedir first
    // TODO(mitchellh): support nesting (config-file in a config file)
    // TODO(mitchellh): detect cycles when nesting
    if (config.@"config-file".list.items.len > 0) {
        const len = config.@"config-file".list.items.len;
        for (config.@"config-file".list.items) |path| {
            var file = try cwd.openFile(path, .{});
            defer file.close();

            var buf_reader = std.io.bufferedReader(file.reader());
            var iter = cli_args.lineIterator(buf_reader.reader());

            try cli_args.parse(Config, alloc, &config, &iter);

            // We don't currently support adding more config files to load
            // from within a loaded config file. This can be supported
            // later.
            if (config.@"config-file".list.items.len > len)
                return error.ConfigFileInConfigFile;
        }
    }
    try config.finalize();
    std.log.debug("config={}", .{config});

    // We want to log all our errors
    glfw.setErrorCallback(glfwErrorCallback);

    // Run our app
    var app = try App.create(alloc, &config);
    defer app.destroy();
    try app.run();
}

// Required by tracy/tracy.zig to enable/disable tracy support.
pub fn tracy_enabled() bool {
    return options.tracy_enabled;
}

pub const std_options = struct {
    // Our log level is always at least info in every build mode.
    pub const log_level: std.log.Level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    };

    // The function std.log will call.
    pub fn logFn(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // Stuff we can do before the lock
        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

        // Lock so we are thread-safe
        std.debug.getStderrMutex().lock();
        defer std.debug.getStderrMutex().unlock();

        // On Mac, we use unified logging. To view this:
        //
        //   sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
        //
        if (builtin.os.tag == .macos) {
            // Convert our levels to Mac levels
            const mac_level: macos.os.LogType = switch (level) {
                .debug => .debug,
                .info => .info,
                .warn => .err,
                .err => .fault,
            };

            // Initialize a logger. This is slow to do on every operation
            // but we shouldn't be logging too much.
            const logger = macos.os.Log.create("com.mitchellh.ghostty", @tagName(scope));
            defer logger.release();
            logger.log(std.heap.c_allocator, mac_level, format, args);
        }

        // Always try default to send to stderr
        const stderr = std.io.getStdErr().writer();
        nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch return;
    }
};

fn glfwErrorCallback(code: glfw.ErrorCode, desc: [:0]const u8) void {
    std.log.warn("glfw error={} message={s}", .{ code, desc });

    // Workaround for: https://github.com/ocornut/imgui/issues/5908
    // If we get an invalid value with "scancode" in the message we assume
    // it is from the glfw key callback that imgui sets and we clear the
    // error so that our future code doesn't crash.
    if (code == glfw.ErrorCode.InvalidValue and
        std.mem.indexOf(u8, desc, "scancode") != null)
    {
        _ = glfw.getError();
    }
}

test {
    _ = @import("Pty.zig");
    _ = @import("Command.zig");
    _ = @import("TempDir.zig");
    _ = @import("font/main.zig");
    _ = @import("renderer.zig");
    _ = @import("termio.zig");
    _ = @import("input.zig");

    // Libraries
    _ = @import("segmented_pool.zig");
    _ = @import("terminal/main.zig");

    // TODO
    _ = @import("blocking_queue.zig");
    _ = @import("config.zig");
    _ = @import("homedir.zig");
    _ = @import("passwd.zig");
    _ = @import("xdg.zig");
    _ = @import("cli_args.zig");
    _ = @import("lru.zig");
}
