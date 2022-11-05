//! Represents the IO thread logic. The IO thread is responsible for
//! the child process and pty management.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const libuv = @import("libuv");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../blocking_queue.zig").BlockingQueue;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);

/// The type used for sending messages to the IO thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
const Mailbox = BlockingQueue(termio.message.IO, 64);

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

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

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

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    return Thread{
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .impl = impl,
        .mailbox = mailbox,
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

    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(alloc);

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
    var data = try self.impl.threadEnter(self.loop);
    defer data.deinit();
    defer self.impl.threadExit(data);

    // Set up our async handler to support rendering
    self.wakeup.setData(self);
    defer self.wakeup.setData(null);

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("exiting IO thread", .{});
    _ = try self.loop.run(.default);
}

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(self: *Thread) !void {
    // This holds the mailbox lock for the duration of the drain. The
    // expectation is that all our message handlers will be non-blocking
    // ENOUGH to not mess up throughput on producers.
    var drain = self.mailbox.drain();
    defer drain.deinit();

    while (drain.next()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .resize => |v| try self.impl.resize(v.grid_size, v.screen_size),
        }
    }
}

fn wakeupCallback(h: *libuv.Async) void {
    const t = h.getData(Thread) orelse {
        // This shouldn't happen so we log it.
        log.warn("wakeup callback fired without data set", .{});
        return;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});
}

fn stopCallback(h: *libuv.Async) void {
    h.loop().stop();
}
