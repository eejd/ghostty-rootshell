/// SelectionGesture manages gesture-based selection logic (mouse press, drag,
/// etc.). Callers setup initial state, make calls for various external
/// events, and react to the requested effects.
const SelectionGesture = @This();

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const ScreenSet = @import("ScreenSet.zig");
const Terminal = @import("Terminal.zig");

/// The tracked pin of the initial left click along with the screen
/// that the pin is part of.
left_click_pin: ?*Pin,
left_click_screen: ScreenSet.Key,
left_click_screen_generation: usize,

/// The count of clicks to count double and triple clicks and so on.
/// The left click time was the last time the left click was done, if the
/// caller could provide one. If this is null then we only support single clicks.
left_click_count: u3,
left_click_time: ?std.time.Instant,

/// The starting xpos/ypos of the left click. Note that if scrolling occurs,
/// these will point to different cells, but the xpos/ypos will stay
/// stable during scrolling relative to the surface.
left_click_xpos: f64,
left_click_ypos: f64,

pub const init: SelectionGesture = .{
    .left_click_pin = null,
    .left_click_count = 0,
    .left_click_time = null,
    .left_click_screen = .primary,
    .left_click_screen_generation = 0,
    .left_click_xpos = 0,
    .left_click_ypos = 0,
};

pub fn deinit(self: *SelectionGesture, t: *Terminal) void {
    // Grab our pagelist that is associated with the pin. If it doesn't
    // exist anymore then our tracked pin is already free.
    const pin = self.left_click_pin orelse return;
    if (t.screens.generation(self.left_click_screen) != self.left_click_screen_generation) return;
    const screen = t.screens.get(self.left_click_screen) orelse return;
    screen.pages.untrackPin(pin);
}

/// Reset any active gesture state and untrack the tracked click pin.
pub fn reset(self: *SelectionGesture, t: *Terminal) void {
    self.left_click_count = 0;
    self.left_click_time = null;
    self.untrackPin(t);
}

pub const Press = struct {
    /// The time when the press event occurred. Use a monotonic timer.
    /// This can be null if you're on a system that doesn't support
    /// time for some reason. In that case, we only support single clicks.
    time: ?std.time.Instant,

    /// The cell where the click was.
    pin: Pin,

    /// The x/y value of the click relative to the surface with (0,0) being
    /// top-left. This is used for distance detection for multi-clicks so
    /// double/triple clicks too far away from each other will reset the click
    /// count as well more accurate drag behaviors.
    xpos: f64,
    ypos: f64,

    /// Maximum distance a click can be from the original click to register
    /// as a repeat. If uncertain, set this to cell width.
    max_distance: f64,

    /// The maximum interval in nanoseconds that a press is considered
    /// a repeat e.g. to record double/triple clicks.
    repeat_interval: u64,
};

/// Record a press event.
pub fn press(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) Allocator.Error!void {
    if (self.left_click_count > 0) {
        if (self.pressRepeat(t, p)) {
            // Successful repeat, return.
            return;
        } else |err| switch (err) {
            error.PressRequiresReset => {},
        }
    }

    // Initial click or the repeat failed for some reason such as
    // the subsequent click being too far away.
    try self.pressInitial(t, p);
}

fn pressInitial(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) Allocator.Error!void {
    // Setup our pin first, reusing our existing pin if we can.
    if (self.left_click_pin) |pin| {
        if (comptime std.debug.runtime_safety) {
            assert(self.left_click_screen == t.screens.active_key);
            assert(self.left_click_screen_generation == t.screens.generation(t.screens.active_key));
        }
        pin.* = p.pin;
    } else {
        const screens: *const ScreenSet = &t.screens;
        self.left_click_pin = try screens.active.pages.trackPin(p.pin);
        errdefer comptime unreachable;
        self.left_click_screen = screens.active_key;
        self.left_click_screen_generation = screens.generation(screens.active_key);
    }
    errdefer comptime unreachable;
    self.left_click_count = 1;
    self.left_click_xpos = p.xpos;
    self.left_click_ypos = p.ypos;
    self.left_click_time = p.time;
}

fn pressRepeat(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) error{PressRequiresReset}!void {
    errdefer {
        self.left_click_count = 0;
        self.untrackPin(t);
    }

    // If too much time has passed then we always reset.
    const time = p.time orelse return error.PressRequiresReset;
    {
        const prev_time = self.left_click_time orelse return error.PressRequiresReset;
        const since = time.since(prev_time);
        if (since > p.repeat_interval) return error.PressRequiresReset;
    }

    // If the click is too far away from the initial click we can't continue.
    const distance = @sqrt(
        std.math.pow(f64, p.xpos - self.left_click_xpos, 2) +
            std.math.pow(f64, p.ypos - self.left_click_ypos, 2),
    );
    if (distance > p.max_distance) return error.PressRequiresReset;

    // If our prior click was on another screen then free and reset. "Another screen"
    // doesn't just mean alt vs primary, it could mean an alt screen that was
    // recycled since we free tracked pins on recycle.
    const screens: *const ScreenSet = &t.screens;
    if (self.left_click_screen != screens.active_key or
        screens.generation(self.left_click_screen) !=
            self.left_click_screen_generation)
    {
        // The error return will trigger the top-level errdefer which
        // will reset our pin.
        return error.PressRequiresReset;
    }

    self.left_click_time = time;
    self.left_click_count = @min(
        self.left_click_count + 1,
        3, // We only support triple clicks max
    );
}

fn untrackPin(self: *SelectionGesture, t: *Terminal) void {
    // Can't untrack unless we have a pin.
    const pin = self.left_click_pin orelse return;
    self.left_click_pin = null;

    // If the generation changed our pin is already invalid.
    const screens: *const ScreenSet = &t.screens;
    if (screens.generation(self.left_click_screen) != self.left_click_screen_generation) return;

    // If we can't get a screen then its already freed.
    const screen = screens.get(self.left_click_screen) orelse return;
    screen.pages.untrackPin(pin);
}

fn testPress(t: *Terminal, x: u16, y: u32, time: ?std.time.Instant) Press {
    return .{
        .time = time,
        .pin = t.screens.active.pages.pin(.{ .active = .{
            .x = x,
            .y = y,
        } }).?,
        .xpos = @floatFromInt(x),
        .ypos = @floatFromInt(y),
        .max_distance = 1,
        .repeat_interval = std.math.maxInt(u64),
    };
}

test "SelectionGesture press records initial click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 2, time));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(time, gesture.left_click_time.?);
    try testing.expectEqual(@as(f64, 1), gesture.left_click_xpos);
    try testing.expectEqual(@as(f64, 2), gesture.left_click_ypos);
}

test "SelectionGesture repeat increments click count" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 1, time));
    try gesture.press(&t, testPress(&t, 1, 1, time));

    try testing.expectEqual(@as(u3, 2), gesture.left_click_count);
}

test "SelectionGesture repeat clamps at triple click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    for (0..4) |_| try gesture.press(&t, testPress(&t, 1, 1, time));

    try testing.expectEqual(@as(u3, 3), gesture.left_click_count);
}

test "SelectionGesture null initial time stays single click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    try gesture.press(&t, testPress(&t, 1, 1, null));
    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expect(gesture.left_click_time != null);
}

test "SelectionGesture null repeat time stays single click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));
    try gesture.press(&t, testPress(&t, 1, 1, null));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(@as(?std.time.Instant, null), gesture.left_click_time);
}

test "SelectionGesture distant press resets click count" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 1, time));
    try gesture.press(&t, testPress(&t, 4, 1, time));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(@as(f64, 4), gesture.left_click_xpos);
}

test "SelectionGesture expired repeat resets click count" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    var event = testPress(&t, 1, 1, try std.time.Instant.now());
    event.repeat_interval = 0;
    try gesture.press(&t, event);

    std.Thread.sleep(std.time.ns_per_ms);
    event.time = try std.time.Instant.now();
    try gesture.press(&t, event);

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
}

test "SelectionGesture screen switch resets click count" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    const primary_tracked = t.screens.active.pages.countTrackedPins();
    try gesture.press(&t, testPress(&t, 1, 1, time));

    _ = try t.screens.getInit(testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    try gesture.press(&t, testPress(&t, 1, 1, time));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(.alternate, gesture.left_click_screen);
    try testing.expectEqual(primary_tracked, t.screens.get(.primary).?.pages.countTrackedPins());
}

test "SelectionGesture removed screen resets without untracking stale pin" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    _ = try t.screens.getInit(testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));

    t.screens.switchTo(.primary);
    t.screens.remove(testing.allocator, .alternate);
    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(.primary, gesture.left_click_screen);
}

test "SelectionGesture deinit untracks pin" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    const tracked = t.screens.active.pages.countTrackedPins();
    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    gesture.deinit(&t);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
