//! This benchmark tests the performance of the terminal stream
//! handler from input to terminal state update. This is useful to
//! test general throughput of VT parsing and handling.
//!
//! Note that the handler used for this benchmark isn't the full
//! terminal handler, since that requires a significant amount of
//! state. This is a simplified version that only handles specific
//! terminal operations like printing characters. We should expand
//! this to include more operations to improve the accuracy of the
//! benchmark.
//!
//! It is a fairly broad benchmark that can be used to determine
//! if we need to optimize something more specific (e.g. the parser).
const TerminalStream = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const Terminal = terminalpkg.Terminal;
const Stream = terminalpkg.Stream(*Handler);

terminal: Terminal,
handler: Handler,
stream: Stream,

pub const Options = struct {
    /// The size of the terminal. This affects benchmarking when
    /// dealing with soft line wrapping and the memory impact
    /// of page sizes.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,
};

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    args: Options,
) !*TerminalStream {
    const ptr = try alloc.create(TerminalStream);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .terminal = try .init(alloc, .{
            .rows = args.@"terminal-rows",
            .cols = args.@"terminal-cols",
        }),
        .handler = .{ .t = &ptr.terminal },
        .stream = .{ .handler = &ptr.handler },
    };

    return ptr;
}

pub fn destroy(self: *TerminalStream, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalStream) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    self.terminal.fullReset();
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    _ = self;
}

/// Implements the handler interface for the terminal.Stream.
/// We should expand this to include more operations to make
/// our benchmark more realistic.
const Handler = struct {
    t: *Terminal,

    pub fn print(self: *Handler, cp: u21) !void {
        try self.t.print(cp);
    }
};

test TerminalStream {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *TerminalStream = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
