//! CADisplayLink wrapper for iOS/visionOS vsync-synchronized rendering.
//!
//! This provides a similar interface to the macOS CVDisplayLink wrapper,
//! allowing the renderer to receive callbacks at display refresh rate.
//!
//! Key differences from CVDisplayLink:
//! - CADisplayLink runs on a run loop (we use the main run loop)
//! - Callbacks fire on the run loop's thread (main thread)
//! - Uses Objective-C target/action pattern internally
//!
//! We create a dynamic Objective-C class to act as the CADisplayLink target,
//! which then invokes a C function callback.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const macos = @import("macos");

const log = std.log.scoped(.ios_display_link);

/// NSRunLoopCommonModes constant from Foundation
pub extern "c" const NSRunLoopCommonModes: *anyopaque;

/// Mirror of Core Animation's `CAFrameRateRange` (three C `float`s). Passed by
/// value to `-[CADisplayLink setPreferredFrameRateRange:]`.
const CAFrameRateRange = extern struct {
    minimum: f32,
    maximum: f32,
    preferred: f32,
};

/// Singleton subclass for the CADisplayLink target.
var TargetClass: ?objc.Class = null;

pub const IOSDisplayLink = struct {
    /// The CADisplayLink instance (null until start() is called)
    link: ?objc.Object,

    /// The target object that receives the callback
    target: objc.Object,

    /// Whether the display link is currently running
    running: bool = false,

    pub const Error = error{
        ObjCFailed,
        InvalidOperation,
    };

    pub const Callback = *const fn (*IOSDisplayLink, ?*anyopaque) void;

    /// Create a new IOSDisplayLink.
    ///
    /// Unlike CVDisplayLink which can be created without a callback,
    /// CADisplayLink requires a target and selector at creation time.
    /// We defer actual creation until start() is called.
    pub fn init() Error!*IOSDisplayLink {
        const alloc = std.heap.c_allocator;
        const self = alloc.create(IOSDisplayLink) catch return error.ObjCFailed;
        errdefer alloc.destroy(self);

        // Create our target object that will receive CADisplayLink callbacks
        const target_class = try getTargetClass();
        const target = target_class.msgSend(
            objc.Object,
            objc.sel("alloc"),
            .{},
        ).msgSend(
            objc.Object,
            objc.sel("init"),
            .{},
        );
        errdefer target.release();

        // Store a pointer to ourselves in the target so the callback can find us
        const self_ptr: ?*anyopaque = @ptrCast(self);
        target.setInstanceVariable("display_link_ptr", objc.Object.fromId(self_ptr));

        self.* = .{
            .link = null,
            .target = target,
            .running = false,
        };

        return self;
    }

    pub fn release(self: *IOSDisplayLink) void {
        // Must be sync, not async stop(). An async stop() dispatches a block
        // that captures `self` by pointer and runs on the main queue later;
        // if we destroy `self` here before the queue drains, the block
        // dereferences freed memory and crashes in `objc_msgSend("invalidate")`
        // on a stale CADisplayLink. invalidateSync flushes any previously
        // queued start/stop blocks (FIFO) before returning, so by the time we
        // reach the release/destroy below, nothing references `self` anymore.
        self.invalidateSync();

        if (self.link) |link| {
            link.release();
        }
        self.target.release();

        const alloc = std.heap.c_allocator;
        alloc.destroy(self);
    }

    /// Set the callback function and userdata.
    pub fn setOutputCallback(
        self: *IOSDisplayLink,
        comptime Userdata: type,
        comptime callbackFn: *const fn (*IOSDisplayLink, ?*Userdata) void,
        userinfo: ?*Userdata,
    ) Error!void {
        // Create a wrapper function that casts the context
        const wrapper = struct {
            fn call(link: *IOSDisplayLink, ctx: ?*anyopaque) void {
                callbackFn(link, @ptrCast(@alignCast(ctx)));
            }
        };

        // Store the callback and userdata in instance variables
        const fn_ptr: ?*anyopaque = @ptrCast(@constCast(&wrapper.call));
        self.target.setInstanceVariable("callback_fn", objc.Object.fromId(fn_ptr));

        const ctx_ptr: ?*anyopaque = @ptrCast(userinfo);
        self.target.setInstanceVariable("callback_ctx", objc.Object.fromId(ctx_ptr));
    }

    /// Start the display link.
    ///
    /// Safe to call from any thread: `addToRunLoop:forMode:` and the
    /// CADisplayLink creation are routed onto the main thread because
    /// CADisplayLink and NSRunLoop are not thread-safe. Calling them from
    /// the renderer thread (as we used to) leaves the display link in an
    /// inconsistent state across iOS background/foreground transitions —
    /// suspect cause of the "one frame per touch" wedge users hit on
    /// scene resume.
    ///
    /// Off-main calls dispatch async (not sync). dispatch_sync would
    /// deadlock with apprt code that's waiting on the renderer thread —
    /// e.g. the iOS background path's drainRendererToIdle blocks on a
    /// renderer-signaled event while the renderer is processing the
    /// visibility change that triggered our start/stop call. async lets
    /// the renderer thread continue, the main thread will run the
    /// addToRunLoop/invalidate block as soon as it's free.
    pub fn start(self: *IOSDisplayLink) Error!void {
        const NSThread = objc.getClass("NSThread") orelse return error.ObjCFailed;
        if (NSThread.msgSend(bool, "isMainThread", .{})) {
            return self.startOnMain();
        }

        var block = StartStopBlock.init(.{ .self = self }, &startCallback);
        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }

    /// Stop the display link.
    /// Note: After calling invalidate() on a CADisplayLink, it cannot be reused.
    /// A new display link will be created on the next start() call.
    ///
    /// Safe to call from any thread (see `start()` for rationale, including
    /// why we use dispatch_async rather than dispatch_sync).
    pub fn stop(self: *IOSDisplayLink) Error!void {
        const NSThread = objc.getClass("NSThread") orelse return error.ObjCFailed;
        if (NSThread.msgSend(bool, "isMainThread", .{})) {
            self.stopOnMain();
            return;
        }

        var block = StartStopBlock.init(.{ .self = self }, &stopCallback);
        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }

    /// Synchronously invalidate the display link and clear the callback
    /// userdata pointer. After this returns, no more `tick:` callbacks can
    /// fire and any in-flight tick that has already resolved the target
    /// object will early-return at the callback null-check.
    ///
    /// This is the safe teardown path: call it from `Surface.deinit` after
    /// the renderer thread has joined but BEFORE `Thread.deinit` destroys
    /// the wakeup mach port. The async stop() path used by setVisible/
    /// setFocus/loopExit cannot guarantee this ordering: ticks can fire
    /// between port destruction and the queued invalidate, dereferencing
    /// a recycled (potentially guarded) port name.
    ///
    /// Unlike stop(), this uses dispatch_sync. That's safe at deinit time
    /// because the renderer thread has already joined and there's no
    /// `drainRendererToIdle` blocker on the main thread (see stop() for
    /// the deadlock case this would otherwise create). Caller must not be
    /// holding any lock the main thread might be waiting on.
    pub fn invalidateSync(self: *IOSDisplayLink) void {
        const NSThread = objc.getClass("NSThread") orelse {
            log.warn("NSThread class not found; skipping invalidateSync", .{});
            return;
        };
        if (NSThread.msgSend(bool, "isMainThread", .{})) {
            self.invalidateOnMain();
            return;
        }

        var block = StartStopBlock.init(.{ .self = self }, &invalidateCallback);
        macos.dispatch.dispatch_sync(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }

    /// Main-thread implementation of `invalidateSync()`. Caller must
    /// guarantee they're on the main thread.
    fn invalidateOnMain(self: *IOSDisplayLink) void {
        // Clear callback ivars first so any in-flight tick that has
        // already resolved the target id but not yet read these will
        // null-check and early-return at the `if (callback_fn) |cb|`
        // gate in the tick method.
        const null_obj = objc.Object.fromId(@as(?*anyopaque, null));
        self.target.setInstanceVariable("callback_fn", null_obj);
        self.target.setInstanceVariable("callback_ctx", null_obj);

        // Then stop and invalidate. CADisplayLink.invalidate detaches
        // synchronously from the run loop, so no more ticks can fire.
        self.stopOnMain();
    }

    /// Main-thread implementation of `start()`. Caller must guarantee
    /// they're on the main thread.
    fn startOnMain(self: *IOSDisplayLink) Error!void {
        if (self.running) return;

        // Create the CADisplayLink if we haven't already
        const link = self.link orelse link: {
            const CADisplayLink = objc.getClass("CADisplayLink") orelse return error.ObjCFailed;
            const new_link = CADisplayLink.msgSend(
                objc.Object,
                objc.sel("displayLinkWithTarget:selector:"),
                .{ self.target.value, objc.sel("tick:") },
            );

            if (new_link.value == null) return error.ObjCFailed;

            // Retain the link since displayLinkWithTarget returns autoreleased
            const retained = new_link.retain();

            // Opt into ProMotion. Without an explicit frame-rate range an
            // iPhone caps the display link at 60Hz even when the app sets
            // `CADisableMinimumFrameDurationOnPhone` (iPad runs the same link
            // at 120Hz by default, hence the iPhone-only stutter). The system
            // clamps this range to the panel's real maximum, so hardcoding
            // 120 is safe on 60Hz iPhones and 90Hz visionOS alike. minimum=60
            // lets Core Animation settle to a steady 60 when content is static.
            const range: CAFrameRateRange = .{ .minimum = 60, .maximum = 120, .preferred = 120 };
            retained.msgSend(void, objc.sel("setPreferredFrameRateRange:"), .{range});

            self.link = retained;
            break :link retained;
        };

        // Add to the main run loop
        const NSRunLoop = objc.getClass("NSRunLoop") orelse return error.ObjCFailed;
        const mainLoop = NSRunLoop.msgSend(objc.Object, objc.sel("mainRunLoop"), .{});

        link.msgSend(
            void,
            objc.sel("addToRunLoop:forMode:"),
            .{ mainLoop.value, NSRunLoopCommonModes },
        );

        self.running = true;
        log.debug("CADisplayLink started", .{});
    }

    /// Main-thread implementation of `stop()`. Caller must guarantee
    /// they're on the main thread.
    fn stopOnMain(self: *IOSDisplayLink) void {
        if (!self.running) return;

        if (self.link) |link| {
            link.msgSend(void, objc.sel("invalidate"), .{});
            link.release();
            self.link = null; // Must create new link on next start()
        }

        self.running = false;
        log.debug("CADisplayLink stopped", .{});
    }

    const StartStopBlock = objc.Block(struct {
        self: *IOSDisplayLink,
    }, .{}, void);

    fn startCallback(block: *const StartStopBlock.Context) callconv(.c) void {
        block.self.startOnMain() catch |err| {
            log.warn("CADisplayLink startOnMain failed err={}", .{err});
        };
    }

    fn stopCallback(block: *const StartStopBlock.Context) callconv(.c) void {
        block.self.stopOnMain();
    }

    fn invalidateCallback(block: *const StartStopBlock.Context) callconv(.c) void {
        block.self.invalidateOnMain();
    }

    /// Check if the display link is running.
    pub fn isRunning(self: *const IOSDisplayLink) bool {
        return self.running;
    }

    /// Get the target class, creating it if necessary.
    fn getTargetClass() Error!objc.Class {
        if (TargetClass) |c| return c;

        const NSObject = objc.getClass("NSObject") orelse return error.ObjCFailed;

        var subclass = objc.allocateClassPair(
            NSObject,
            "GhosttyDisplayLinkTarget",
        ) orelse return error.ObjCFailed;
        errdefer objc.disposeClassPair(subclass);

        // Add instance variables for callback and context
        if (!subclass.addIvar("display_link_ptr")) return error.ObjCFailed;
        if (!subclass.addIvar("callback_fn")) return error.ObjCFailed;
        if (!subclass.addIvar("callback_ctx")) return error.ObjCFailed;

        // Add the tick: method that CADisplayLink will call
        subclass.replaceMethod("tick:", struct {
            fn tick(target_id: objc.c.id, sel: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
                _ = sel;
                _ = sender;

                const target = objc.Object.fromId(target_id);

                // Get the IOSDisplayLink pointer
                const link_ptr: ?*IOSDisplayLink = @ptrCast(@alignCast(
                    target.getInstanceVariable("display_link_ptr").value,
                ));

                // Get the callback function and context
                const callback_fn: ?*const fn (*IOSDisplayLink, ?*anyopaque) void = @ptrCast(
                    target.getInstanceVariable("callback_fn").value,
                );
                const callback_ctx: ?*anyopaque = @ptrCast(
                    target.getInstanceVariable("callback_ctx").value,
                );

                if (link_ptr) |link| {
                    if (callback_fn) |cb| {
                        cb(link, callback_ctx);
                    }
                }
            }
        }.tick);

        objc.registerClassPair(subclass);
        TargetClass = subclass;

        return subclass;
    }
};
