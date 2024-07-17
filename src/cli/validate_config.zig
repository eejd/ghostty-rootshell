const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Config = @import("../config.zig").Config;
const cli = @import("../cli.zig");

pub const Options = struct {
    /// The path of the config file to validate
    @"config-file": ?[:0]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `validate-config` command is used to validate a Ghostty config
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    // If a config path is passed, validate it, otherwise validate default configs
    if (opts.@"config-file") |config_path| {
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const abs_path = try std.fs.cwd().realpath(config_path, &buf);

        try cfg.loadFile(alloc, abs_path);
    } else {
        try cfg.loadDefaultFiles(alloc);
    }

    if (!cfg._errors.empty()) {
        for (cfg._errors.list.items) |err| {
            try stdout.print("{s}\n", .{err.message});
        }

        return 1;
    }

    return 1;
}
