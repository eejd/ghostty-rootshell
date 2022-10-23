//! This has a helper for embedding libuv in another event loop.
//! This is an extension of libuv and not a helper built-in to libuv
//! itself, although it uses official APIs of libuv to enable the
//! functionality.

const Embed = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Loop = @import("Loop.zig");
const Thread = @import("Thread.zig");
const Mutex = @import("Mutex.zig");
const Cond = @import("Cond.zig");

const log = std.log.scoped(.libuv_embed);

const BoolAtomic = std.atomic.Atomic(bool);

loop: Loop,
mutex: Mutex,
cond: Cond,
ready: bool = false,
terminate: BoolAtomic,
callback: std.meta.FnPtr(fn () void),
thread: ?Thread,

/// Initialize a new embedder. The callback is called when libuv should
/// tick. The callback should be as fast as possible.
pub fn init(
    alloc: Allocator,
    loop: Loop,
    callback: std.meta.FnPtr(fn () void),
) !Embed {
    return Embed{
        .loop = loop,
        .mutex = try Mutex.init(alloc),
        .cond = try Cond.init(alloc),
        .terminate = BoolAtomic.init(false),
        .callback = callback,
        .thread = null,
    };
}

/// Deinit the embed struct. This will not automatically terminate
/// the embed thread. You must call stop manually.
pub fn deinit(self: *Embed, alloc: Allocator) void {
    self.mutex.deinit(alloc);
    self.cond.deinit(alloc);
    self.* = undefined;
}

/// Start the thread that runs the embed logic and calls callback
/// when the libuv loop should tick. This must only be called once.
pub fn start(self: *Embed) !void {
    self.thread = try Thread.initData(self, Embed.threadMain);
}

/// Stop stops the embed thread and blocks until the thread joins.
pub fn stop(self: *Embed) void {
    if (self.thread == null) return;

    // Mark that we want to terminate
    self.terminate.store(true, .SeqCst);

    // Post to the semaphore to ensure that any waits are processed.
    self.cond.broadcast();
}

/// Wait for the thread backing the embedding to end.
pub fn join(self: *Embed) !void {
    if (self.thread) |*thr| {
        try thr.join();
        self.thread = null;
    }
}

/// loopRun runs the next tick of the libuv event loop. This should be
/// called by the main loop thread as a result of callback making some
/// signal. This should NOT be called from callback.
pub fn loopRun(self: *Embed) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.ready) {
        self.ready = false;
        _ = try self.loop.run(.nowait);
        self.cond.broadcast();
    }
}

fn threadMain(self: *Embed) void {
    while (self.terminate.load(.SeqCst) == false) {
        const fd = self.loop.backendFd() catch unreachable;
        const timeout = self.loop.backendTimeout();

        switch (builtin.os.tag) {
            // epoll
            .linux => {
                var ev: [1]std.os.linux.epoll_event = undefined;
                _ = std.os.epoll_wait(fd, &ev, timeout);
            },

            // kqueue
            .macos, .dragonfly, .freebsd, .openbsd, .netbsd => {
                var ts: std.os.timespec = .{
                    .tv_sec = @divTrunc(timeout, 1000),
                    .tv_nsec = @mod(timeout, 1000) * 1000000,
                };

                // Important: for kevent to block properly, it needs an
                // EMPTY changeset and a NON-EMPTY event set.
                var changes: [0]std.os.Kevent = undefined;
                var events: [1]std.os.Kevent = undefined;
                _ = std.os.kevent(
                    fd,
                    &changes,
                    &events,
                    if (timeout < 0) null else &ts,
                ) catch |err| blk: {
                    log.err("kevent error: {}", .{err});
                    break :blk 0;
                };
            },

            else => @compileError("unsupported libuv Embed platform"),
        }

        // Call our trigger
        self.callback();

        // Wait for libuv to run a tick.
        //
        // NOTE: we use timedwait because I /believe/ there is a race here
        // with gflw post event that sometimes causes it not to receive it.
        // Therefore, if too much time passes, we just go back and loop
        // through the poller.
        //
        // TODO: this is suboptimal for performance. There as to be a better
        // way to do this.
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ready = true;
        _ = self.cond.timedwait(self.mutex, 10 * 1000000);
    }
}

test "Embed" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    var embed = try init(testing.allocator, loop, (struct {
        fn callback() void {}
    }).callback);
    defer embed.deinit(testing.allocator);

    // This just tests that the thread can start and then stop.
    // It doesn't do much else at the moment
    try embed.start();
    embed.stop();
    try embed.join();
}
