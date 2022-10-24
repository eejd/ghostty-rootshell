const std = @import("std");
const stream = @import("stream.zig");

pub const c = @import("c.zig");
pub const Loop = @import("Loop.zig");
pub const Async = @import("Async.zig");
pub const Idle = @import("Idle.zig");
pub const Pipe = @import("Pipe.zig");
pub const Timer = @import("Timer.zig");
pub const Tty = @import("Tty.zig");
pub const Cond = @import("Cond.zig");
pub const Mutex = @import("Mutex.zig");
pub const Sem = @import("Sem.zig");
pub const Thread = @import("Thread.zig");
pub const WriteReq = stream.WriteReq;

pub const Embed = @import("Embed.zig");

pub usingnamespace @import("error.zig");

test {
    // Leak a loop... I don't know why but this fixes CI failures. Probably
    // a miscompilation or something. TODO: double check this once self-hosted
    // lands to see if we need this.
    _ = try Loop.init(std.heap.page_allocator);

    _ = @import("tests.zig");
    _ = stream;

    _ = Loop;
    _ = Async;
    _ = Idle;
    _ = Pipe;
    _ = Timer;
    _ = Tty;
    _ = Cond;
    _ = Mutex;
    _ = Sem;
    _ = Thread;

    _ = Embed;
}
