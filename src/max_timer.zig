const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const libuv = @import("libuv");

/// A coalescing timer that forces a run after a certain maximum time
/// since the last run. This is used for example by the renderer to try
/// to render at a high FPS but gracefully fall back under high IO load so
/// that we can process more data and increase throughput.
pub fn MaxTimer(comptime cb: fn (*libuv.Timer) void) type {
    return struct {
        const Self = @This();

        /// The underlying libuv timer.
        timer: libuv.Timer,

        /// The maximum time between timer calls. This is best effort based on
        /// event loop load. If the event loop is busy, the timer will be run on
        /// the next available tick.
        max: u64,

        /// The fastest the timer will ever run.
        min: u64,

        /// The last time this timer ran.
        last: u64 = 0,

        /// This handle is used to wake up the event loop when the timer
        /// is restarted.
        async_h: libuv.Async,

        pub fn init(
            loop: libuv.Loop,
            data: ?*anyopaque,
            min: u64,
            max: u64,
        ) !Self {
            const alloc = loop.getData(Allocator).?.*;
            var timer = try libuv.Timer.init(alloc, loop);
            timer.setData(data);

            // The async handle is used to wake up the event loop. This is
            // necessary since stop/starting a timer doesn't trigger the
            // poll on the backend fd.
            var async_h = try libuv.Async.init(alloc, loop, (struct {
                fn callback(_: *libuv.Async) void {}
            }).callback);

            // The maximum time can't be less than the interval otherwise this
            // will just constantly fire. if (max < min) return error.MaxShorterThanTimer;
            return Self{
                .timer = timer,
                .min = min,
                .max = max,
                .async_h = async_h,
            };
        }

        pub fn deinit(self: *Self) void {
            self.async_h.close((struct {
                fn callback(h: *libuv.Async) void {
                    const alloc = h.loop().getData(Allocator).?.*;
                    h.deinit(alloc);
                }
            }).callback);

            self.timer.close((struct {
                fn callback(t: *libuv.Timer) void {
                    const alloc = t.loop().getData(Allocator).?.*;
                    t.deinit(alloc);
                }
            }).callback);
        }

        /// This should be called from the callback to update the last called time.
        pub fn tick(self: *Self) void {
            self.timer.loop().updateTime();
            self.last = self.timer.loop().now();
            self.timer.stop() catch unreachable;
        }

        /// Schedule the timer to run. If the timer is not started, it'll
        /// run on the next min tick. If the timer is started, this will
        /// delay the timer up to max time since the last run.
        pub fn schedule(self: *Self) !void {
            // If the timer hasn't been started, start it now and schedule
            // a tick as soon as possible.
            if (!try self.timer.isActive()) {
                try self.timer.start(cb, self.min, self.min);

                // We have to send an async message to wake up the
                // event loop. Starting a timer doesn't write to the fd.
                try self.async_h.send();
                return;
            }

            // If we are past the max time, we run the timer now.
            try self.timer.stop();
            self.timer.loop().updateTime();
            const timeout = if (self.timer.loop().now() - self.last > self.max)
                0
            else
                self.min;

            // We still have time, restart the timer so that it is min time away.
            try self.timer.start(cb, timeout, 0);
        }
    };
}
