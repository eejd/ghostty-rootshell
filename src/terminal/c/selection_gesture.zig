const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const SelectionGesture = @import("../SelectionGesture.zig");
const grid_ref = @import("grid_ref.zig");
const terminal_c = @import("terminal.zig");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.selection_gesture_c);

/// C: GhosttySelectionGesture
pub const Gesture = ?*GestureWrapper;

const GestureWrapper = struct {
    alloc: std.mem.Allocator,
    gesture: SelectionGesture = .init,
};

/// C: GhosttySelectionGestureBehavior
pub const Behavior = SelectionGesture.Behavior;

/// C: GhosttySelectionGestureAutoscroll
pub const Autoscroll = SelectionGesture.Autoscroll;

/// C: GhosttySelectionGestureData
pub const Data = enum(c_int) {
    click_count = 0,
    dragged = 1,
    autoscroll = 2,
    behavior = 3,
    anchor = 4,

    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .click_count => u8,
            .dragged => bool,
            .autoscroll => Autoscroll,
            .behavior => Behavior,
            .anchor => grid_ref.CGridRef,
        };
    }
};

pub fn new(
    alloc_: ?*const CAllocator,
    out_gesture: ?*Gesture,
) callconv(lib.calling_conv) Result {
    const out = out_gesture orelse return .invalid_value;

    const alloc = lib.alloc.default(alloc_);
    const gesture = alloc.create(GestureWrapper) catch {
        out.* = null;
        return .out_of_memory;
    };
    gesture.* = .{
        .alloc = alloc,
    };
    out.* = gesture;
    return .success;
}

pub fn free(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) void {
    const wrapper = gesture_ orelse return;
    if (terminal_c.zigTerminal(terminal)) |t| {
        wrapper.gesture.deinit(t);
    }
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}

pub fn reset(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) void {
    const wrapper = gesture_ orelse return;
    const t = terminal_c.zigTerminal(terminal) orelse return;
    wrapper.gesture.reset(t);
}

pub fn get(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Data, @intFromEnum(data)) catch {
            log.warn("selection_gesture_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    const out_ptr = out orelse return .invalid_value;
    return switch (data) {
        inline else => |comptime_data| getTyped(
            gesture_,
            terminal,
            comptime_data,
            @ptrCast(@alignCast(out_ptr)),
        ),
    };
}

pub fn get_multi(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
    count: usize,
    keys: ?[*]const Data,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = get(gesture_, terminal, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn getTyped(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const wrapper = gesture_ orelse return .invalid_value;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;

    switch (data) {
        .click_count => out.* = wrapper.gesture.left_click_count,
        .dragged => out.* = wrapper.gesture.left_click_dragged,
        .autoscroll => out.* = wrapper.gesture.left_drag_autoscroll,
        .behavior => out.* = wrapper.gesture.left_click_behavior,
        .anchor => {
            const pin = wrapper.gesture.validatedLeftClickPin(&t.screens) orelse
                return .no_value;
            out.* = .fromPin(pin.*);
        },
    }

    return .success;
}

test "selection gesture lifecycle and get" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var click_count: u8 = 255;
    try testing.expectEqual(Result.success, get(gesture, terminal, .click_count, &click_count));
    try testing.expectEqual(@as(u8, 0), click_count);

    var dragged = true;
    try testing.expectEqual(Result.success, get(gesture, terminal, .dragged, &dragged));
    try testing.expect(!dragged);

    var autoscroll: Autoscroll = .up;
    try testing.expectEqual(Result.success, get(gesture, terminal, .autoscroll, &autoscroll));
    try testing.expectEqual(Autoscroll.none, autoscroll);

    var behavior: Behavior = .word;
    try testing.expectEqual(Result.success, get(gesture, terminal, .behavior, &behavior));
    try testing.expectEqual(Behavior.cell, behavior);

    var anchor: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.no_value, get(gesture, terminal, .anchor, &anchor));
}

test "selection gesture get_multi" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    const keys = [_]Data{ .click_count, .dragged, .autoscroll, .behavior };
    var click_count: u8 = 255;
    var dragged = true;
    var autoscroll: Autoscroll = .up;
    var behavior: Behavior = .word;
    var values = [_]?*anyopaque{
        &click_count,
        &dragged,
        &autoscroll,
        &behavior,
    };
    var written: usize = 0;

    try testing.expectEqual(Result.success, get_multi(
        gesture,
        terminal,
        keys.len,
        &keys,
        &values,
        &written,
    ));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(@as(u8, 0), click_count);
    try testing.expect(!dragged);
    try testing.expectEqual(Autoscroll.none, autoscroll);
    try testing.expectEqual(Behavior.cell, behavior);
}

test "selection gesture get_multi returns first failing index" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    const keys = [_]Data{ .click_count, .anchor, .dragged };
    var click_count: u8 = 255;
    var anchor: grid_ref.CGridRef = undefined;
    var dragged = true;
    var values = [_]?*anyopaque{ &click_count, &anchor, &dragged };
    var written: usize = 0;

    try testing.expectEqual(Result.no_value, get_multi(
        gesture,
        terminal,
        keys.len,
        &keys,
        &values,
        &written,
    ));
    try testing.expectEqual(@as(usize, 1), written);
    try testing.expectEqual(@as(u8, 0), click_count);
    try testing.expect(dragged);
}

test "selection gesture free null" {
    free(null, null);
}
