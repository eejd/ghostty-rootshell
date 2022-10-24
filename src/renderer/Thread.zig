//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const libuv = @import("libuv");
const renderer = @import("../renderer.zig");
const gl = @import("../opengl.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);

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

/// The windo we're rendering to.
window: glfw.Window,

/// The underlying renderer implementation.
renderer: *renderer.OpenGL,

/// Pointer to the shared state that is used to generate the final render.
state: *renderer.State,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    window: glfw.Window,
    renderer_impl: *renderer.OpenGL,
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

    return Thread{
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .window = window,
        .renderer = renderer_impl,
        .state = state,
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
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    // Get a copy to our allocator
    // const alloc_ptr = self.loop.getData(Allocator).?;
    // const alloc = alloc_ptr.*;

    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    const Renderer = RendererType();
    if (@hasDecl(Renderer, "threadEnter")) try self.renderer.threadEnter(self.window);
    defer if (@hasDecl(Renderer, "threadExit")) self.renderer.threadExit();

    // Set up our async handler to support rendering
    self.wakeup.setData(self);
    defer self.wakeup.setData(null);

    // Set up our timer and start it for rendering
    self.render_h.setData(self);
    defer self.render_h.setData(null);
    try self.wakeup.send();

    // Run
    log.debug("starting renderer thread", .{});
    defer log.debug("exiting renderer thread", .{});
    _ = try self.loop.run(.default);
}

fn wakeupCallback(h: *libuv.Async) void {
    const t = h.getData(Thread) orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return;
    };

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

fn stopCallback(h: *libuv.Async) void {
    h.loop().stop();
}

// This is unnecessary right now but is logic we'll need for when we
// abstract renderers out.
fn RendererType() type {
    const self: Thread = undefined;
    return switch (@typeInfo(@TypeOf(self.renderer))) {
        .Pointer => |p| p.child,
        .Struct => |s| s,
        else => unreachable,
    };
}
