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

    // If a config path is passed, validate it, otherwise validate usual config options
    if (opts.@"config-file") |config_path| {
        const cwd = std.fs.cwd();

        if (cwd.openFile(config_path, .{})) |file| {
            defer file.close();

            var cfg = try Config.default(alloc);
            defer cfg.deinit();

            var buf_reader = std.io.bufferedReader(file.reader());
            var iter = cli.args.lineIterator(buf_reader.reader());
            try cfg.loadIter(alloc, &iter);
            try cfg.loadRecursiveFiles(alloc);
            try cfg.finalize();
        } else |err| {
            try stdout.print("{any}", .{err});
        }
    } else {
        _ = try Config.load(alloc);
    }

    return 0;
}
