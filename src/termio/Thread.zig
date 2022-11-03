//! Represents the IO thread logic. The IO thread is responsible for
//! the child process and pty management.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const libuv = @import("libuv");
const termio = @import("../termio.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);

/// The main event loop for the thread. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: libuv.Loop,

/// This can be used to wake up the thread.
wakeup: libuv.Async,

/// This can be used to stop the thread on the next loop iteration.
stop: libuv.Async,

/// The underlying IO implementation.
impl: *termio.Impl,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    impl: *termio.Impl,
) !Thread {
    // We always store allocator pointer on the loop data so that
    // handles can use our global allocator.
    const allocPtr = try alloc.create(Allocator);
    errdefer alloc.destroy(allocPtr);
    allocPtr.* = alloc;

    // Create our event loop.
    var loop = try libuv.Loop.init(alloc);
    errdefer loop.deinit(alloc);
    loop.setData(allocPtr);

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try libuv.Async.init(alloc, loop, wakeupCallback);
    errdefer wakeup_h.close((struct {
        fn callback(h: *libuv.Async) void {
            const loop_alloc = h.loop().getData(Allocator).?.*;
            h.deinit(loop_alloc);
        }
    }).callback);

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try libuv.Async.init(alloc, loop, stopCallback);
    errdefer stop_h.close((struct {
        fn callback(h: *libuv.Async) void {
            const loop_alloc = h.loop().getData(Allocator).?.*;
            h.deinit(loop_alloc);
        }
    }).callback);

    return Thread{
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .impl = impl,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    // Get a copy to our allocator
    const alloc_ptr = self.loop.getData(Allocator).?;
    const alloc = alloc_ptr.*;

    // Schedule our handles to close
    self.stop.close((struct {
        fn callback(h: *libuv.Async) void {
            const handle_alloc = h.loop().getData(Allocator).?.*;
            h.deinit(handle_alloc);
        }
    }).callback);
    self.wakeup.close((struct {
        fn callback(h: *libuv.Async) void {
            const handle_alloc = h.loop().getData(Allocator).?.*;
            h.deinit(handle_alloc);
        }
    }).callback);

    // Run the loop one more time, because destroying our other things
    // like windows usually cancel all our event loop stuff and we need
    // one more run through to finalize all the closes.
    _ = self.loop.run(.default) catch |err|
        log.err("error finalizing event loop: {}", .{err});

    // Dealloc our allocator copy
    alloc.destroy(alloc_ptr);

    self.loop.deinit(alloc);
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("error in io thread err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    // Run our thread start/end callbacks. This allows the implementation
    // to hook into the event loop as needed.
    try self.impl.threadEnter(self.loop);
    defer self.impl.threadExit();

    // Set up our async handler to support rendering
    self.wakeup.setData(self);
    defer self.wakeup.setData(null);

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("exiting IO thread", .{});
    _ = try self.loop.run(.default);
}

fn wakeupCallback(h: *libuv.Async) void {
    _ = h;
    // const t = h.getData(Thread) orelse {
    //     // This shouldn't happen so we log it.
    //     log.warn("render callback fired without data set", .{});
    //     return;
    // };
}

fn stopCallback(h: *libuv.Async) void {
    h.loop().stop();
}
