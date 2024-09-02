const std = @import("std");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Config = @import("../config.zig").Config;
const sentry = @import("../crash/sentry.zig");

pub const Options = struct {
    /// View the crash report locally (unimplemented).
    view: ?[:0]const u8 = null,

    /// Send the crash report to the Ghostty community (unimplemented).
    send: ?[:0]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `crash-report command is used to list/view/send crash reports.
///
/// When executed without any arguments, this will list any existing crash reports.
///
/// The `--view` argument can be used to inspect a particular crash report.
///
/// The `--send` argument can be used to send a crash report to the Ghostty community.
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();

    if (opts.view) |_| {
        try stdout.writeAll("viewing crash reports is unimplemented\n");
        return 1;
    }

    if (opts.send) |_| {
        try stdout.writeAll("sending crash reports is unimplemented\n");
        return 1;
    }

    if (try sentry.listCrashReports(alloc)) |reports| {
        defer {
            for (reports) |report| {
                alloc.free(report.name);
            }
            alloc.free(reports);
        }

        std.mem.sort(sentry.CrashReport, reports, {}, lt);
        try stdout.print("\n       {d:} crash reports!\n\n", .{reports.len});

        for (reports, 0..) |report, count| {
            var buf: [128]u8 = undefined;
            const now = std.time.nanoTimestamp();
            const diff = now - report.mtime;
            const since = if (diff < 0) "now" else s: {
                const d = Config.Duration{ .duration = @intCast(diff) };
                break :s try std.fmt.bufPrint(&buf, "{s} ago", .{d.round(std.time.ns_per_s)});
            };
            try stdout.print("{d: >4} — {s} ({s})\n", .{ count, report.name, since });
        }
        try stdout.writeAll("\n");
    } else {
        try stdout.writeAll("\n       No crash reports! 👻\n\n");
    }

    return 0;
}

fn lt(_: void, lhs: sentry.CrashReport, rhs: sentry.CrashReport) bool {
    return lhs.mtime > rhs.mtime;
}
