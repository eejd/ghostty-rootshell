const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const SelectionGesture = @import("../SelectionGesture.zig");
const selection_codepoints = @import("../selection_codepoints.zig");
const grid_ref = @import("grid_ref.zig");
const selection_c = @import("selection.zig");
const terminal_c = @import("terminal.zig");
const types = @import("types.zig");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.selection_gesture_c);

/// C: GhosttySelectionGesture
pub const Gesture = ?*GestureWrapper;

/// C: GhosttySelectionGestureEvent
pub const Event = ?*EventWrapper;

const GestureWrapper = struct {
    alloc: std.mem.Allocator,
    gesture: SelectionGesture = .init,
};

const EventWrapper = struct {
    alloc: std.mem.Allocator,
    event: union(EventType) {
        press: SelectionGesture.Press,
    },

    // Press.pin has no safe sentinel value: PageList.Pin contains a non-null
    // node pointer and is undefined until the C caller provides a GhosttyGridRef.
    // Track that separately so event execution can reject a press whose required
    // ref option was never set, or was later cleared.
    press_pin_set: bool = false,

    // Backing storage for Press.word_boundary_codepoints. The C API receives
    // codepoints as borrowed uint32_t values, but SelectionGesture.Press stores
    // a []const u21 slice. We copy/convert into event-owned storage so the real
    // Press payload can safely point at it until the event is changed or freed.
    word_boundary_codepoints: ?[]u21 = null,

    // Backing storage for Press.behaviors. The C API sets behaviors as a value
    // struct, but SelectionGesture.Press stores a pointer to a [3]Behavior.
    // Keep the array on the event wrapper so the Press payload can point at a
    // stable location for the lifetime of the event.
    behaviors: [3]Behavior = SelectionGesture.default_behaviors,

    fn init(self: *EventWrapper, event_type: EventType) void {
        self.event = switch (event_type) {
            .press => .{ .press = self.defaultPress() },
        };
    }

    fn defaultPress(self: *EventWrapper) SelectionGesture.Press {
        return .{
            .time = null,
            .pin = undefined,
            .xpos = 0,
            .ypos = 0,
            .max_distance = 0,
            .repeat_interval = 0,
            .word_boundary_codepoints = &selection_codepoints.default_word_boundaries,
            .behaviors = &self.behaviors,
        };
    }

    fn deinit(self: *EventWrapper) void {
        if (self.word_boundary_codepoints) |cps| {
            if (cps.len > 0) self.alloc.free(cps);
        }
    }
};

/// C: GhosttySelectionGestureBehavior
pub const Behavior = SelectionGesture.Behavior;

/// C: GhosttySelectionGestureAutoscroll
pub const Autoscroll = SelectionGesture.Autoscroll;

/// C: GhosttySelectionGestureBehaviors
pub const Behaviors = extern struct {
    single_click: Behavior,
    double_click: Behavior,
    triple_click: Behavior,
};

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

/// C: GhosttySelectionGestureEventType
pub const EventType = enum(c_int) {
    press = 0,
};

/// C: GhosttySelectionGestureEventOption
pub const EventOption = enum(c_int) {
    ref = 0,
    position = 1,
    repeat_distance = 2,
    time_ns = 3,
    repeat_interval_ns = 4,
    word_boundary_codepoints = 5,
    behaviors = 6,

    pub fn Type(comptime self: EventOption) type {
        return switch (self) {
            .ref => grid_ref.CGridRef,
            .position => types.SurfacePosition,
            .repeat_distance => f64,
            .time_ns => u64,
            .repeat_interval_ns => u64,
            .word_boundary_codepoints => types.Codepoints,
            .behaviors => Behaviors,
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

pub fn event_new(
    alloc_: ?*const CAllocator,
    out_event: ?*Event,
    event_type: EventType,
) callconv(lib.calling_conv) Result {
    const out = out_event orelse return .invalid_value;
    _ = std.meta.intToEnum(EventType, @intFromEnum(event_type)) catch
        return .invalid_value;

    const alloc = lib.alloc.default(alloc_);
    const event = alloc.create(EventWrapper) catch {
        out.* = null;
        return .out_of_memory;
    };
    event.* = .{
        .alloc = alloc,
        .event = undefined,
    };
    event.init(event_type);
    out.* = event;
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

pub fn event_free(event_: Event) callconv(lib.calling_conv) void {
    const event = event_ orelse return;
    event.deinit();
    const alloc = event.alloc;
    alloc.destroy(event);
}

pub fn reset(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) void {
    const wrapper = gesture_ orelse return;
    const t = terminal_c.zigTerminal(terminal) orelse return;
    wrapper.gesture.reset(t);
}

pub fn handle_event(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
    event_: Event,
    out_selection: ?*selection_c.CSelection,
) callconv(lib.calling_conv) Result {
    const wrapper = gesture_ orelse return .invalid_value;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const event_wrapper = event_ orelse return .invalid_value;

    return switch (event_wrapper.event) {
        .press => |press| {
            if (!event_wrapper.press_pin_set) return .invalid_value;
            const sel = wrapper.gesture.press(t, press) catch return .out_of_memory;
            if (out_selection) |out| {
                out.* = selection_c.CSelection.fromZig(sel orelse return .no_value);
            } else if (sel == null) return .no_value;
            return .success;
        },
    };
}

pub fn event_set(
    event_: Event,
    option: EventOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(EventOption, @intFromEnum(option)) catch {
            log.warn("selection_gesture_event_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| eventSetTyped(
            event_,
            comptime_option,
            if (value) |ptr| @ptrCast(@alignCast(ptr)) else null,
        ),
    };
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

fn eventSetTyped(
    event_: Event,
    comptime option: EventOption,
    value: ?*const option.Type(),
) Result {
    const event = event_ orelse return .invalid_value;
    return switch (event.event) {
        .press => |*press| pressSetTyped(event, press, option, value),
    };
}

fn pressSetTyped(
    event: *EventWrapper,
    press: *SelectionGesture.Press,
    comptime option: EventOption,
    value: ?*const option.Type(),
) Result {
    const v = value orelse {
        switch (option) {
            .ref => event.press_pin_set = false,
            .position => {
                press.xpos = 0;
                press.ypos = 0;
            },
            .repeat_distance => press.max_distance = 0,
            .time_ns => press.time = null,
            .repeat_interval_ns => press.repeat_interval = 0,
            .word_boundary_codepoints => clearPressCodepoints(event, press),
            .behaviors => {
                event.behaviors = SelectionGesture.default_behaviors;
                press.behaviors = &event.behaviors;
            },
        }
        return .success;
    };

    switch (option) {
        .ref => {
            press.pin = v.toPin() orelse return .invalid_value;
            event.press_pin_set = true;
        },
        .position => {
            press.xpos = v.x;
            press.ypos = v.y;
        },
        .repeat_distance => press.max_distance = v.*,
        .time_ns => press.time = instantFromNs(v.*),
        .repeat_interval_ns => press.repeat_interval = v.*,
        .word_boundary_codepoints => {
            if (v.len > 0 and v.ptr == null) return .invalid_value;
            clearPressCodepoints(event, press);
            const ptr = v.ptr orelse {
                event.word_boundary_codepoints = &.{};
                press.word_boundary_codepoints = event.word_boundary_codepoints.?;
                return .success;
            };
            const copy = event.alloc.alloc(u21, v.len) catch return .out_of_memory;
            errdefer event.alloc.free(copy);
            for (copy, ptr[0..v.len]) |*dst, cp| {
                dst.* = std.math.cast(u21, cp) orelse return .invalid_value;
            }
            event.word_boundary_codepoints = copy;
            press.word_boundary_codepoints = copy;
        },
        .behaviors => {
            if (!validBehavior(v.single_click) or
                !validBehavior(v.double_click) or
                !validBehavior(v.triple_click)) return .invalid_value;
            event.behaviors = .{ v.single_click, v.double_click, v.triple_click };
            press.behaviors = &event.behaviors;
        },
    }

    return .success;
}

fn clearPressCodepoints(event: *EventWrapper, press: *SelectionGesture.Press) void {
    if (event.word_boundary_codepoints) |cps| {
        if (cps.len > 0) event.alloc.free(cps);
    }
    event.word_boundary_codepoints = null;
    press.word_boundary_codepoints = &selection_codepoints.default_word_boundaries;
}

fn instantFromNs(ns: u64) std.time.Instant {
    return switch (builtin.os.tag) {
        .windows, .uefi, .wasi => .{ .timestamp = ns },
        else => .{ .timestamp = .{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        } },
    };
}

fn validBehavior(behavior: Behavior) bool {
    _ = std.meta.intToEnum(Behavior, @intFromEnum(behavior)) catch return false;
    return true;
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

test "selection gesture event set clear and free" {
    var event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &event,
        .press,
    ));
    defer event_free(event);

    const in_pos: types.SurfacePosition = .{ .x = 12.5, .y = -3.25 };
    try testing.expectEqual(Result.success, event_set(event, .position, &in_pos));
    try testing.expectEqual(@as(f64, 12.5), event.?.event.press.xpos);
    try testing.expectEqual(@as(f64, -3.25), event.?.event.press.ypos);

    try testing.expectEqual(Result.success, event_set(event, .position, null));
    try testing.expectEqual(@as(f64, 0), event.?.event.press.xpos);
    try testing.expectEqual(@as(f64, 0), event.?.event.press.ypos);

    const repeat_distance: f64 = 4.0;
    try testing.expectEqual(Result.success, event_set(event, .repeat_distance, &repeat_distance));
    try testing.expectEqual(repeat_distance, event.?.event.press.max_distance);
}

test "selection gesture event copies clears and frees codepoints" {
    var event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &event,
        .press,
    ));
    defer event_free(event);

    var values = [_]u32{ ' ', '\t' };
    const in: types.Codepoints = .{ .ptr = &values, .len = values.len };
    try testing.expectEqual(Result.success, event_set(event, .word_boundary_codepoints, &in));

    values[0] = 'x';

    try testing.expectEqual(@as(usize, 2), event.?.event.press.word_boundary_codepoints.len);
    try testing.expectEqual(@as(u21, ' '), event.?.event.press.word_boundary_codepoints[0]);
    try testing.expectEqual(@as(u21, '\t'), event.?.event.press.word_boundary_codepoints[1]);

    const invalid: types.Codepoints = .{ .ptr = null, .len = 1 };
    try testing.expectEqual(Result.invalid_value, event_set(event, .word_boundary_codepoints, &invalid));

    try testing.expectEqual(Result.success, event_set(event, .word_boundary_codepoints, null));
    try testing.expectEqual(
        selection_codepoints.default_word_boundaries.len,
        event.?.event.press.word_boundary_codepoints.len,
    );

    const empty: types.Codepoints = .{ .ptr = null, .len = 0 };
    try testing.expectEqual(Result.success, event_set(event, .word_boundary_codepoints, &empty));
    try testing.expectEqual(@as(usize, 0), event.?.event.press.word_boundary_codepoints.len);
}

test "selection gesture event behaviors" {
    var event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &event,
        .press,
    ));
    defer event_free(event);

    const in: Behaviors = .{
        .single_click = .cell,
        .double_click = .word,
        .triple_click = .line,
    };
    try testing.expectEqual(Result.success, event_set(event, .behaviors, &in));
    try testing.expectEqual(Behavior.cell, event.?.event.press.behaviors[0]);
    try testing.expectEqual(Behavior.word, event.?.event.press.behaviors[1]);
    try testing.expectEqual(Behavior.line, event.?.event.press.behaviors[2]);
}

test "selection gesture event applies press" {
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

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    terminal_c.vt_write(terminal, "abc", 3);

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &ref));
    const behaviors: Behaviors = .{
        .single_click = .word,
        .double_click = .word,
        .triple_click = .line,
    };
    try testing.expectEqual(Result.success, event_set(press_event, .behaviors, &behaviors));

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, handle_event(gesture, terminal, press_event, &sel));
    try testing.expectEqual(@as(u16, 0), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 2), sel.end.toPin().?.x);

    try testing.expectEqual(Result.success, handle_event(gesture, terminal, press_event, null));
}

test "selection gesture event press requires ref" {
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

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.invalid_value, handle_event(gesture, terminal, press_event, &sel));
}

test "selection gesture event null output still reports no selection" {
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

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &ref));

    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, press_event, null));
}

test "selection gesture free null" {
    free(null, null);
}

test "selection gesture event free null" {
    event_free(null);
}
