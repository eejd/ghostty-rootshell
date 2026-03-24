const std = @import("std");
const testing = std.testing;
const lib = @import("../../lib/main.zig");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const ZigTerminal = @import("../Terminal.zig");
const Stream = @import("../stream_terminal.zig").Stream;
const ScreenSet = @import("../ScreenSet.zig");
const PageList = @import("../PageList.zig");
const kitty = @import("../kitty/key.zig");
const modes = @import("../modes.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const size_report = @import("../size_report.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const grid_ref_c = @import("grid_ref.zig");
const style_c = @import("style.zig");
const Result = @import("result.zig").Result;

const Handler = @import("../stream_terminal.zig").Handler;

const log = std.log.scoped(.terminal_c);

/// Wrapper around ZigTerminal that tracks additional state for C API usage,
/// such as the persistent VT stream needed to handle escape sequences split
/// across multiple vt_write calls.
const TerminalWrapper = struct {
    terminal: *ZigTerminal,
    stream: Stream,
    effects: Effects = .{},
};

/// C callback state for terminal effects. Trampolines are always
/// installed on the stream handler; they check these fields and
/// no-op when the corresponding callback is null.
const Effects = struct {
    userdata: ?*anyopaque = null,
    write_pty: ?WritePtyFn = null,
    bell: ?BellFn = null,
    enquiry: ?EnquiryFn = null,
    xtversion: ?XtversionFn = null,
    title_changed: ?TitleChangedFn = null,
    size_cb: ?SizeFn = null,

    /// C function pointer type for the write_pty callback.
    pub const WritePtyFn = *const fn (Terminal, ?*anyopaque, [*]const u8, usize) callconv(.c) void;

    /// C function pointer type for the bell callback.
    pub const BellFn = *const fn (Terminal, ?*anyopaque) callconv(.c) void;

    /// C function pointer type for the enquiry callback.
    /// Returns the response bytes. The memory must remain valid
    /// until the callback returns.
    pub const EnquiryFn = *const fn (Terminal, ?*anyopaque) callconv(.c) lib.String;

    /// C function pointer type for the xtversion callback.
    /// Returns the version string (e.g. "ghostty 1.2.3"). The memory
    /// must remain valid until the callback returns. An empty string
    /// (len=0) causes the default "libghostty" to be reported.
    pub const XtversionFn = *const fn (Terminal, ?*anyopaque) callconv(.c) lib.String;

    /// C function pointer type for the title_changed callback.
    pub const TitleChangedFn = *const fn (Terminal, ?*anyopaque) callconv(.c) void;

    /// C function pointer type for the size callback.
    /// Returns true and fills out_size if size is available,
    /// or returns false to silently ignore the query.
    pub const SizeFn = *const fn (Terminal, ?*anyopaque, *size_report.Size) callconv(.c) bool;

    fn writePtyTrampoline(handler: *Handler, data: [:0]const u8) void {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.write_pty orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata, data.ptr, data.len);
    }

    fn bellTrampoline(handler: *Handler) void {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.bell orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }

    fn enquiryTrampoline(handler: *Handler) []const u8 {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.enquiry orelse return "";
        const result = func(@ptrCast(wrapper), wrapper.effects.userdata);
        if (result.len == 0) return "";
        return result.ptr[0..result.len];
    }

    fn xtversionTrampoline(handler: *Handler) []const u8 {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.xtversion orelse return "";
        const result = func(@ptrCast(wrapper), wrapper.effects.userdata);
        if (result.len == 0) return "";
        return result.ptr[0..result.len];
    }

    fn titleChangedTrampoline(handler: *Handler) void {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.title_changed orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }

    fn sizeTrampoline(handler: *Handler) ?size_report.Size {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.size_cb orelse return null;
        var s: size_report.Size = undefined;
        if (func(@ptrCast(wrapper), wrapper.effects.userdata, &s)) return s;
        return null;
    }
};

/// C: GhosttyTerminal
pub const Terminal = ?*TerminalWrapper;

/// C: GhosttyTerminalOptions
pub const Options = extern struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback: usize,
};

const NewError = error{
    InvalidValue,
    OutOfMemory,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Terminal,
    opts: Options,
) callconv(.c) Result {
    result.* = new_(alloc_, opts) catch |err| {
        result.* = null;
        return switch (err) {
            error.InvalidValue => .invalid_value,
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn new_(
    alloc_: ?*const CAllocator,
    opts: Options,
) NewError!*TerminalWrapper {
    if (opts.cols == 0 or opts.rows == 0) return error.InvalidValue;

    const alloc = lib_alloc.default(alloc_);
    const t = alloc.create(ZigTerminal) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(t);

    const wrapper = alloc.create(TerminalWrapper) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(wrapper);

    // Setup our terminal
    t.* = try .init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback = opts.max_scrollback,
    });
    errdefer t.deinit(alloc);

    // Setup our stream with trampolines always installed so that
    // setting C callbacks at any time takes effect immediately.
    var handler: Stream.Handler = t.vtHandler();
    handler.effects.write_pty = &Effects.writePtyTrampoline;
    handler.effects.bell = &Effects.bellTrampoline;
    handler.effects.enquiry = &Effects.enquiryTrampoline;
    handler.effects.xtversion = &Effects.xtversionTrampoline;
    handler.effects.title_changed = &Effects.titleChangedTrampoline;
    handler.effects.size = &Effects.sizeTrampoline;

    wrapper.* = .{
        .terminal = t,
        .stream = .initAlloc(alloc, handler),
    };

    return wrapper;
}

pub fn vt_write(
    terminal_: Terminal,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) void {
    const wrapper = terminal_ orelse return;
    wrapper.stream.nextSlice(ptr[0..len]);
}

/// C: GhosttyTerminalOption
pub const Option = enum(c_int) {
    userdata = 0,
    write_pty = 1,
    bell = 2,
    enquiry = 3,
    xtversion = 4,
    title_changed = 5,
    size_cb = 6,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .userdata => ?*anyopaque,
            .write_pty => ?Effects.WritePtyFn,
            .bell => ?Effects.BellFn,
            .enquiry => ?Effects.EnquiryFn,
            .xtversion => ?Effects.XtversionFn,
            .title_changed => ?Effects.TitleChangedFn,
            .size_cb => ?Effects.SizeFn,
        };
    }
};

pub fn set(
    terminal_: Terminal,
    option: Option,
    value: ?*const anyopaque,
) callconv(.c) void {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Option, @intFromEnum(option)) catch {
            log.warn("terminal_set invalid option value={d}", .{@intFromEnum(option)});
            return;
        };
    }

    return switch (option) {
        inline else => |comptime_option| setTyped(
            terminal_,
            comptime_option,
            @ptrCast(@alignCast(value)),
        ),
    };
}

fn setTyped(
    terminal_: Terminal,
    comptime option: Option,
    value: ?*const option.InType(),
) void {
    const wrapper = terminal_ orelse return;
    switch (option) {
        .userdata => wrapper.effects.userdata = if (value) |v| v.* else null,
        .write_pty => wrapper.effects.write_pty = if (value) |v| v.* else null,
        .bell => wrapper.effects.bell = if (value) |v| v.* else null,
        .enquiry => wrapper.effects.enquiry = if (value) |v| v.* else null,
        .xtversion => wrapper.effects.xtversion = if (value) |v| v.* else null,
        .title_changed => wrapper.effects.title_changed = if (value) |v| v.* else null,
        .size_cb => wrapper.effects.size_cb = if (value) |v| v.* else null,
    }
}

/// C: GhosttyTerminalScrollViewport
pub const ScrollViewport = ZigTerminal.ScrollViewport.C;

pub fn scroll_viewport(
    terminal_: Terminal,
    behavior: ScrollViewport,
) callconv(.c) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.scrollViewport(switch (behavior.tag) {
        .top => .top,
        .bottom => .bottom,
        .delta => .{ .delta = behavior.value.delta },
    });
}

pub fn resize(
    terminal_: Terminal,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    if (cols == 0 or rows == 0) return .invalid_value;
    t.resize(t.gpa(), cols, rows) catch return .out_of_memory;
    return .success;
}

pub fn reset(terminal_: Terminal) callconv(.c) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.fullReset();
}

pub fn mode_get(
    terminal_: Terminal,
    tag: modes.ModeTag.Backing,
    out_value: *bool,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const mode_tag: modes.ModeTag = @bitCast(tag);
    const mode = modes.modeFromInt(mode_tag.value, mode_tag.ansi) orelse return .invalid_value;
    out_value.* = t.modes.get(mode);
    return .success;
}

pub fn mode_set(
    terminal_: Terminal,
    tag: modes.ModeTag.Backing,
    value: bool,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const mode_tag: modes.ModeTag = @bitCast(tag);
    const mode = modes.modeFromInt(mode_tag.value, mode_tag.ansi) orelse return .invalid_value;
    t.modes.set(mode, value);
    return .success;
}

/// C: GhosttyTerminalScreen
pub const TerminalScreen = ScreenSet.Key;

/// C: GhosttyTerminalScrollbar
pub const TerminalScrollbar = PageList.Scrollbar.C;

/// C: GhosttyTerminalData
pub const TerminalData = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    cursor_pending_wrap = 5,
    active_screen = 6,
    cursor_visible = 7,
    kitty_keyboard_flags = 8,
    scrollbar = 9,
    cursor_style = 10,
    mouse_tracking = 11,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: TerminalData) type {
        return switch (self) {
            .invalid => void,
            .cols, .rows, .cursor_x, .cursor_y => size.CellCountInt,
            .cursor_pending_wrap, .cursor_visible, .mouse_tracking => bool,
            .active_screen => TerminalScreen,
            .kitty_keyboard_flags => u8,
            .scrollbar => TerminalScrollbar,
            .cursor_style => style_c.Style,
        };
    }
};

pub fn get(
    terminal_: Terminal,
    data: TerminalData,
    out: ?*anyopaque,
) callconv(.c) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(TerminalData, @intFromEnum(data)) catch {
            log.warn("terminal_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            terminal_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    terminal_: Terminal,
    comptime data: TerminalData,
    out: *data.OutType(),
) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    switch (data) {
        .invalid => return .invalid_value,
        .cols => out.* = t.cols,
        .rows => out.* = t.rows,
        .cursor_x => out.* = t.screens.active.cursor.x,
        .cursor_y => out.* = t.screens.active.cursor.y,
        .cursor_pending_wrap => out.* = t.screens.active.cursor.pending_wrap,
        .active_screen => out.* = t.screens.active_key,
        .cursor_visible => out.* = t.modes.get(.cursor_visible),
        .kitty_keyboard_flags => out.* = @as(u8, t.screens.active.kitty_keyboard.current().int()),
        .scrollbar => out.* = t.screens.active.pages.scrollbar().cval(),
        .cursor_style => out.* = .fromStyle(t.screens.active.cursor.style),
        .mouse_tracking => out.* = t.modes.get(.mouse_event_x10) or
            t.modes.get(.mouse_event_normal) or
            t.modes.get(.mouse_event_button) or
            t.modes.get(.mouse_event_any),
    }

    return .success;
}

pub fn grid_ref(
    terminal_: Terminal,
    pt: point.Point.C,
    out_ref: ?*grid_ref_c.CGridRef,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const zig_pt: point.Point = switch (pt.tag) {
        .active => .{ .active = pt.value.active },
        .viewport => .{ .viewport = pt.value.viewport },
        .screen => .{ .screen = pt.value.screen },
        .history => .{ .history = pt.value.history },
    };
    const p = t.screens.active.pages.pin(zig_pt) orelse
        return .invalid_value;
    if (out_ref) |out| out.* = grid_ref_c.CGridRef.fromPin(p);
    return .success;
}

pub fn free(terminal_: Terminal) callconv(.c) void {
    const wrapper = terminal_ orelse return;
    const t = wrapper.terminal;

    wrapper.stream.deinit();
    const alloc = t.gpa();
    t.deinit(alloc);
    alloc.destroy(t);
    alloc.destroy(wrapper);
}

test "new/free" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));

    try testing.expect(t != null);
    free(t);
}

test "new invalid value" {
    var t: Terminal = null;

    try testing.expectEqual(Result.invalid_value, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 0,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    try testing.expect(t == null);

    try testing.expectEqual(Result.invalid_value, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 0,
            .max_scrollback = 10_000,
        },
    ));
    try testing.expect(t == null);
}

test "free null" {
    free(null);
}

test "scroll_viewport" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 5,
            .rows = 2,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    const zt = t.?.terminal;

    // Write "hello" on the first line
    vt_write(t, "hello", 5);

    // Push "hello" into scrollback with 3 newlines (index = ESC D)
    vt_write(t, "\x1bD\x1bD\x1bD", 6);
    {
        // Viewport should be empty now since hello scrolled off
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll to top: "hello" should be visible again
    scroll_viewport(t, .{ .tag = .top, .value = undefined });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Scroll to bottom: viewport should be empty again
    scroll_viewport(t, .{ .tag = .bottom, .value = undefined });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll up by delta to bring "hello" back into view
    scroll_viewport(t, .{ .tag = .delta, .value = .{ .delta = -3 } });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

test "scroll_viewport null" {
    scroll_viewport(null, .{ .tag = .top, .value = undefined });
}

test "reset" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);
    reset(t);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("", str);
}

test "reset null" {
    reset(null);
}

test "resize" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.success, resize(t, 40, 12));
    try testing.expectEqual(40, t.?.terminal.cols);
    try testing.expectEqual(12, t.?.terminal.rows);
}

test "resize null" {
    try testing.expectEqual(Result.invalid_value, resize(null, 80, 24));
}

test "resize invalid value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 0, 24));
    try testing.expectEqual(Result.invalid_value, resize(t, 80, 0));
}

test "mode_get and mode_set" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var value: bool = undefined;

    // DEC mode 25 (cursor_visible) defaults to true
    const cursor_visible: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.success, mode_get(t, cursor_visible, &value));
    try testing.expect(value);

    // Set it to false
    try testing.expectEqual(Result.success, mode_set(t, cursor_visible, false));
    try testing.expectEqual(Result.success, mode_get(t, cursor_visible, &value));
    try testing.expect(!value);

    // ANSI mode 4 (insert) defaults to false
    const insert: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 4, .ansi = true });
    try testing.expectEqual(Result.success, mode_get(t, insert, &value));
    try testing.expect(!value);

    try testing.expectEqual(Result.success, mode_set(t, insert, true));
    try testing.expectEqual(Result.success, mode_get(t, insert, &value));
    try testing.expect(value);
}

test "mode_get null" {
    var value: bool = undefined;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_get(null, tag, &value));
}

test "mode_set null" {
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_set(null, tag, true));
}

test "mode_get unknown mode" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var value: bool = undefined;
    const unknown: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_get(t, unknown, &value));
}

test "mode_set unknown mode" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const unknown: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_set(t, unknown, true));
}

test "vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}

test "vt_write split escape sequence" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    // Write "Hello" in bold by splitting the CSI bold sequence across two writes.
    // ESC [ 1 m  = bold on, ESC [ 0 m = reset
    // Split ESC from the rest of the CSI sequence.
    vt_write(t, "Hello \x1b", 7);
    vt_write(t, "[1mBold\x1b[0m", 10);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    // If the escape sequence leaked, we'd see "[1mBold" as literal text.
    try testing.expectEqualStrings("Hello Bold", str);
}

test "get cols and rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var cols: size.CellCountInt = undefined;
    var rows: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cols, @ptrCast(&cols)));
    try testing.expectEqual(Result.success, get(t, .rows, @ptrCast(&rows)));
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}

test "get cursor position" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var x: size.CellCountInt = undefined;
    var y: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_x, @ptrCast(&x)));
    try testing.expectEqual(Result.success, get(t, .cursor_y, @ptrCast(&y)));
    try testing.expectEqual(5, x);
    try testing.expectEqual(0, y);
}

test "get null" {
    var cols: size.CellCountInt = undefined;
    try testing.expectEqual(Result.invalid_value, get(null, .cols, @ptrCast(&cols)));
}

test "get cursor_visible" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var visible: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(visible);

    // DEC mode 25 controls cursor visibility
    const cursor_visible_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, cursor_visible_mode, false));
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(!visible);
}

test "get active_screen" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var screen: TerminalScreen = undefined;
    try testing.expectEqual(Result.success, get(t, .active_screen, @ptrCast(&screen)));
    try testing.expectEqual(.primary, screen);
}

test "get kitty_keyboard_flags" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var flags: u8 = undefined;
    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(0, flags);

    // Push kitty flags via VT sequence: CSI > 3 u (push disambiguate | report_events)
    vt_write(t, "\x1b[>3u", 5);

    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(3, flags);
}

test "get mouse_tracking" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var tracking: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);

    // Enable X10 mouse (DEC mode 9)
    const x10_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, x10_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable X10, enable normal mouse (DEC mode 1000)
    try testing.expectEqual(Result.success, mode_set(t, x10_mode, false));
    const normal_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1000, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, normal_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable normal, enable button mouse (DEC mode 1002)
    try testing.expectEqual(Result.success, mode_set(t, normal_mode, false));
    const button_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1002, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, button_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable button, enable any mouse (DEC mode 1003)
    try testing.expectEqual(Result.success, mode_set(t, button_mode, false));
    const any_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1003, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, any_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable all - should be false again
    try testing.expectEqual(Result.success, mode_set(t, any_mode, false));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);
}

test "get invalid" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, get(t, .invalid, null));
}

test "grid_ref" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));

    // Extract cell from grid ref and verify it contains 'H'
    var out_cell: cell_c.CCell = undefined;
    try testing.expectEqual(Result.success, grid_ref_c.grid_ref_cell(&out_ref, &out_cell));

    var cp: u32 = 0;
    try testing.expectEqual(Result.success, cell_c.get(out_cell, .codepoint, @ptrCast(&cp)));
    try testing.expectEqual(@as(u32, 'H'), cp);
}

test "grid_ref null terminal" {
    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(null, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));
}

test "set write_pty callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;
        var last_userdata: ?*anyopaque = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
            last_userdata = null;
        }

        fn writePty(_: Terminal, ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
            last_userdata = ud;
        }
    };
    defer S.deinit();

    // Set userdata and write_pty callback
    var sentinel: u8 = 42;
    const ud: ?*anyopaque = @ptrCast(&sentinel);
    set(t, .userdata, @ptrCast(&ud));
    const cb: ?Effects.WritePtyFn = &S.writePty;
    set(t, .write_pty, @ptrCast(&cb));

    // DECRQM for wraparound mode (mode 7, set by default) should trigger write_pty
    vt_write(t, "\x1B[?7$p", 6);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B[?7;1$y", S.last_data.?);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
}

test "set write_pty without callback ignores queries" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // Without setting a callback, DECRQM should be silently ignored (no crash)
    vt_write(t, "\x1B[?7$p", 6);
}

test "set write_pty null clears callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var called: bool = false;
        fn writePty(_: Terminal, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {
            called = true;
        }
    };
    S.called = false;

    // Set then clear the callback
    const cb: ?Effects.WritePtyFn = &S.writePty;
    set(t, .write_pty, @ptrCast(&cb));
    set(t, .write_pty, null);

    vt_write(t, "\x1B[?7$p", 6);
    try testing.expect(!S.called);
}

test "set bell callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var bell_count: usize = 0;
        var last_userdata: ?*anyopaque = null;

        fn bell(_: Terminal, ud: ?*anyopaque) callconv(.c) void {
            bell_count += 1;
            last_userdata = ud;
        }
    };
    S.bell_count = 0;
    S.last_userdata = null;

    // Set userdata and bell callback
    var sentinel: u8 = 99;
    const ud: ?*anyopaque = @ptrCast(&sentinel);
    set(t, .userdata, @ptrCast(&ud));
    const cb: ?Effects.BellFn = &S.bell;
    set(t, .bell, @ptrCast(&cb));

    // Single BEL
    vt_write(t, "\x07", 1);
    try testing.expectEqual(@as(usize, 1), S.bell_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);

    // Multiple BELs
    vt_write(t, "\x07\x07", 2);
    try testing.expectEqual(@as(usize, 3), S.bell_count);
}

test "bell without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // BEL without a callback should not crash
    vt_write(t, "\x07", 1);
}

test "set enquiry callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        const response = "OK";
        fn enquiry(_: Terminal, _: ?*anyopaque) callconv(.c) lib.String {
            return .{ .ptr = response, .len = response.len };
        }
    };
    defer S.deinit();

    const write_cb: ?Effects.WritePtyFn = &S.writePty;
    set(t, .write_pty, @ptrCast(&write_cb));
    const enq_cb: ?Effects.EnquiryFn = &S.enquiry;
    set(t, .enquiry, @ptrCast(&enq_cb));

    // ENQ (0x05) should trigger the enquiry callback and write response via write_pty
    vt_write(t, "\x05", 1);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("OK", S.last_data.?);
}

test "enquiry without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // ENQ without a callback should not crash
    vt_write(t, "\x05", 1);
}

test "set xtversion callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        const version = "myterm 1.0";
        fn xtversion(_: Terminal, _: ?*anyopaque) callconv(.c) lib.String {
            return .{ .ptr = version, .len = version.len };
        }
    };
    defer S.deinit();

    const write_cb: ?Effects.WritePtyFn = &S.writePty;
    set(t, .write_pty, @ptrCast(&write_cb));
    const xtv_cb: ?Effects.XtversionFn = &S.xtversion;
    set(t, .xtversion, @ptrCast(&xtv_cb));

    // XTVERSION: CSI > q
    vt_write(t, "\x1B[>q", 4);
    try testing.expect(S.last_data != null);
    // Response should be DCS >| version ST
    try testing.expectEqualStrings("\x1BP>|myterm 1.0\x1B\\", S.last_data.?);
}

test "xtversion without callback reports default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    // Set write_pty but not xtversion — should get default "libghostty"
    const write_cb: ?Effects.WritePtyFn = &S.writePty;
    set(t, .write_pty, @ptrCast(&write_cb));

    vt_write(t, "\x1B[>q", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1BP>|libghostty\x1B\\", S.last_data.?);
}

test "set title_changed callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var title_count: usize = 0;
        var last_userdata: ?*anyopaque = null;

        fn titleChanged(_: Terminal, ud: ?*anyopaque) callconv(.c) void {
            title_count += 1;
            last_userdata = ud;
        }
    };
    S.title_count = 0;
    S.last_userdata = null;

    var sentinel: u8 = 77;
    const ud: ?*anyopaque = @ptrCast(&sentinel);
    set(t, .userdata, @ptrCast(&ud));
    const cb: ?Effects.TitleChangedFn = &S.titleChanged;
    set(t, .title_changed, @ptrCast(&cb));

    // OSC 2 ; title ST — set window title
    vt_write(t, "\x1B]2;Hello\x1B\\", 10);
    try testing.expectEqual(@as(usize, 1), S.title_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);

    // Another title change
    vt_write(t, "\x1B]2;World\x1B\\", 10);
    try testing.expectEqual(@as(usize, 2), S.title_count);
}

test "title_changed without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // OSC 2 without a callback should not crash
    vt_write(t, "\x1B]2;Hello\x1B\\", 10);
}

test "set size callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn sizeCb(_: Terminal, _: ?*anyopaque, out_size: *size_report.Size) callconv(.c) bool {
            out_size.* = .{
                .rows = 24,
                .columns = 80,
                .cell_width = 8,
                .cell_height = 16,
            };
            return true;
        }
    };
    defer S.deinit();

    const write_cb: ?Effects.WritePtyFn = &S.writePty;
    set(t, .write_pty, @ptrCast(&write_cb));
    const size_cb_fn: ?Effects.SizeFn = &S.sizeCb;
    set(t, .size_cb, @ptrCast(&size_cb_fn));

    // CSI 18 t — report text area size in characters
    vt_write(t, "\x1B[18t", 5);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[8;24;80t", S.last_data.?);
}

test "size without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // CSI 18 t without a size callback should not crash
    vt_write(t, "\x1B[18t", 5);
}

test "grid_ref out of bounds" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 100, .y = 0 } },
    }, &out_ref));
}
