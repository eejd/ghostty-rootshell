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
const log = std.log.named(.renderer_thread);

/// The main event loop for the application. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: libuv.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: libuv.Async,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(alloc: Allocator) !Thread {
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
    var async_h = try libuv.Async.init(alloc, loop, (struct {
        fn callback(_: *libuv.Async) void {}
    }).callback);
    errdefer async_h.close((struct {
        fn callback(h: *libuv.Async) void {
            const loop_alloc = h.loop().getData(Allocator).?.*;
            h.deinit(loop_alloc);
        }
    }).callback);

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .notifier = async_h,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    // Get a copy to our allocator
    const alloc_ptr = self.loop.getData(Allocator).?;
    const alloc = alloc_ptr.*;

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
pub fn threadMain(
    window: glfw.Window,
    renderer_impl: *const renderer.OpenGL,
) void {
    // Call child function so we can use errors...
    threadMain_(
        window,
        renderer_impl,
    ) catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(
    self: *const Thread,
    window: glfw.Window,
    renderer_impl: *const renderer.OpenGL,
) !void {
    const Renderer = switch (@TypeOf(renderer_impl)) {
        .Pointer => |p| p.child,
        .Struct => |s| s,
    };

    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    if (@hasDecl(Renderer, "threadEnter")) try renderer_impl.threadEnter(window);
    defer if (@hasDecl(Renderer, "threadExit")) renderer_impl.threadExit();

    // Setup our timer handle which is used to perform the actual render.
    // TODO

    // Run
    log.debug("starting renderer thread", .{});
    try self.loop.run(.default);
}
