const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");

/// The available actions for the CLI. This is the list of available
/// benchmarks.
const Action = enum {
    @"terminal-stream",

    /// Returns the struct associated with the action. The struct
    /// should have a few decls:
    ///
    ///   - `const Options`: The CLI options for the action.
    ///   - `fn create`: Create a new instance of the action from options.
    ///   - `fn benchmark`: Returns a `Benchmark` instance for the action.
    ///
    /// See TerminalStream for an example.
    pub fn Struct(comptime action: Action) type {
        return switch (action) {
            .@"terminal-stream" => @import("TerminalStream.zig"),
        };
    }
};

/// An entrypoint for the benchmark CLI.
pub fn main() !void {
    // TODO: Better terminal output throughout this, use libvaxis.

    const alloc = std.heap.c_allocator;
    const action_ = try cli.action.detectArgs(Action, alloc);
    const action = action_ orelse return error.NoAction;

    // We need a comptime action to get the struct type and do the
    // rest.
    return switch (action) {
        inline else => |comptime_action| {
            const BenchmarkImpl = Action.Struct(comptime_action);
            try mainAction(BenchmarkImpl, alloc);
        },
    };
}

fn mainAction(comptime BenchmarkImpl: type, alloc: Allocator) !void {
    // First, parse our CLI options.
    const Options = BenchmarkImpl.Options;
    var opts: Options = .{};
    defer if (@hasDecl(Options, "deinit")) opts.deinit();
    {
        var iter = try cli.args.argsIterator(alloc);
        defer iter.deinit();
        try cli.args.parse(Options, alloc, &opts, &iter);
    }

    // Create our implementation
    const impl = try BenchmarkImpl.create(alloc, opts);
    defer impl.destroy(alloc);

    // Initialize our benchmark
    const b = impl.benchmark();
    _ = try b.run(.once);
}
