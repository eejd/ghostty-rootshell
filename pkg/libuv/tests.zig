//! This file contains other behavior tests for the libuv integration.
//! We trust that libuv works, but still test some behaviors to ensure
//! that our wrappers around libuv are working as expected.

const std = @import("std");
const testing = std.testing;
const libuv = @import("main.zig");

test "Async: cancel timer" {
    // Not sure why, but failing in CI... but passes locally. It used
    // to pass before we moved this out to a separate package so I don't
    // know whats going on yet.
    if (@import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;

    const alloc = testing.allocator;
    var loop = try libuv.Loop.init(alloc);
    defer loop.deinit(alloc);

    var timer = try libuv.Timer.init(alloc, loop);
    defer timer.deinit(alloc);

    // Start a timer with a long timeout. This will block our loop.
    try timer.start((struct {
        fn callback(_: *libuv.Timer) void {}
    }).callback, 5000, 5000);

    var async_handle = try libuv.Async.init(testing.allocator, loop, (struct {
        fn callback(v: *libuv.Async) void {
            v.loop().stop();
            v.close(null);
        }
    }).callback);
    defer async_handle.deinit(testing.allocator);
    try async_handle.send();

    // This run through the loop should exit because we called loop stop.
    _ = try loop.run(.default);

    // We need to run the loop one more time to handle all our close callbacks.
    timer.close(null);
    _ = try loop.run(.default);
}
