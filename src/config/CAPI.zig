const std = @import("std");
const cli_args = @import("../cli_args.zig");
const inputpkg = @import("../input.zig");
const global = &@import("../main.zig").state;

const Config = @import("Config.zig");

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = global.alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc) catch |err| {
        log.err("error creating config err={}", .{err});
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc.destroy(v);
    }
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(global.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a string in the same format as
/// the file-based syntax for the desktop version of the terminal.
export fn ghostty_config_load_string(
    self: *Config,
    str: [*]const u8,
    len: usize,
) void {
    config_load_string_(self, str[0..len]) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

fn config_load_string_(self: *Config, str: []const u8) !void {
    var fbs = std.io.fixedBufferStream(str);
    var iter = cli_args.lineIterator(fbs.reader());
    try cli_args.parse(Config, global.alloc, self, &iter);
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(global.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(global.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger {
    const action = try inputpkg.Binding.Action.parse(str);
    return self.keybind.set.getTrigger(action) orelse .{};
}
