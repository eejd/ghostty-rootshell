//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const libuv = @import("libuv");
const renderer = @import("../renderer.zig");
const BlockingQueue = @import("../blocking_queue.zig").BlockingQueue;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);

/// The type used for sending messages to the IO thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
pub const Mailbox = BlockingQueue(renderer.Message, 64);

/// The main event loop for the application. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: libuv.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: libuv.Async,

/// This can be used to stop the renderer on the next loop iteration.
stop: libuv.Async,

/// The timer used for rendering
render_h: libuv.Timer,

/// The timer used for cursor blinking
cursor_h: libuv.Timer,

/// The windo we're rendering to.
window: glfw.Window,

/// The underlying renderer implementation.
renderer: *renderer.Renderer,

/// Pointer to the shared state that is used to generate the final render.
state: *renderer.State,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    window: glfw.Window,
    renderer_impl: *renderer.Renderer,
    state: *renderer.State,
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

    // The primary timer for rendering.
    var render_h = try libuv.Timer.init(alloc, loop);
    errdefer render_h.close((struct {
        fn callback(h: *libuv.Timer) void {
            const loop_alloc = h.loop().getData(Allocator).?.*;
            h.deinit(loop_alloc);
        }
    }).callback);

    // Setup a timer for blinking the cursor
    var cursor_timer = try libuv.Timer.init(alloc, loop);
    errdefer cursor_timer.close((struct {
        fn callback(t: *libuv.Timer) void {
            const alloc_h = t.loop().getData(Allocator).?.*;
            t.deinit(alloc_h);
        }
    }).callback);

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    return Thread{
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .cursor_h = cursor_timer,
        .window = window,
        .renderer = renderer_impl,
        .state = state,
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
    self.render_h.close((struct {
        fn callback(h: *libuv.Timer) void {
            const handle_alloc = h.loop().getData(Allocator).?.*;
            h.deinit(handle_alloc);
        }
    }).callback);
    self.cursor_h.close((struct {
        fn callback(h: *libuv.Timer) void {
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
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    try self.renderer.threadEnter(self.window);
    defer self.renderer.threadExit();

    // Set up our async handler to support rendering
    self.wakeup.setData(self);
    defer self.wakeup.setData(null);

    // Set up our timer and start it for rendering
    self.render_h.setData(self);
    defer self.render_h.setData(null);
    try self.wakeup.send();

    // Setup a timer for blinking the cursor
    self.cursor_h.setData(self);
    try self.cursor_h.start(cursorTimerCallback, 600, 600);

    // Run
    log.debug("starting renderer thread", .{});
    defer log.debug("exiting renderer thread", .{});
    _ = try self.loop.run(.default);
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !void {
    // This holds the mailbox lock for the duration of the drain. The
    // expectation is that all our message handlers will be non-blocking
    // ENOUGH to not mess up throughput on producers.

    var drain = self.mailbox.drain();
    defer drain.deinit();

    while (drain.next()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .focus => |v| {
                // Set it on the renderer
                try self.renderer.setFocus(v);

                if (!v) {
                    // If we're not focused, then we stop the cursor blink
                    try self.cursor_h.stop();
                } else {
                    // If we're focused, we immediately show the cursor again
                    // and then restart the timer.
                    if (!try self.cursor_h.isActive()) {
                        self.renderer.blinkCursor(true);
                        try self.cursor_h.start(
                            cursorTimerCallback,
                            self.cursor_h.getRepeat(),
                            self.cursor_h.getRepeat(),
                        );
                    }
                }
            },

            .reset_cursor_blink => {
                self.renderer.blinkCursor(true);
                if (try self.cursor_h.isActive()) {
                    _ = try self.cursor_h.again();
                }
            },
        }
    }
}

fn wakeupCallback(h: *libuv.Async) void {
    const t = h.getData(Thread) orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});

    // If the timer is already active then we don't have to do anything.
    const active = t.render_h.isActive() catch true;
    if (active) return;

    // Timer is not active, let's start it
    t.render_h.start(renderCallback, 10, 0) catch |err|
        log.warn("render timer failed to start err={}", .{err});
}

fn renderCallback(h: *libuv.Timer) void {
    const t = h.getData(Thread) orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return;
    };

    t.renderer.render(t.window, t.state) catch |err|
        log.warn("error rendering err={}", .{err});
}

fn cursorTimerCallback(h: *libuv.Timer) void {
    const t = h.getData(Thread) orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return;
    };

    t.renderer.blinkCursor(false);
    t.wakeup.send() catch {};
}

fn stopCallback(h: *libuv.Async) void {
    h.loop().stop();
}
