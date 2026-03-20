const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const lib = @import("../../lib/main.zig");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const colorpkg = @import("../color.zig");
const page = @import("../page.zig");
const size = @import("../size.zig");
const Style = @import("../style.zig").Style;
const terminal_c = @import("terminal.zig");
const renderpkg = @import("../render.zig");
const Result = @import("result.zig").Result;
const row = @import("row.zig");

const log = std.log.scoped(.render_state_c);

const RenderStateWrapper = struct {
    alloc: std.mem.Allocator,
    state: renderpkg.RenderState = .empty,
};

const RowIteratorWrapper = struct {
    alloc: std.mem.Allocator,

    /// The current index (also y value) into the row list.
    y: ?size.CellCountInt,

    /// These are the raw pointers into the render state data.
    raws: []const page.Row,
    cells: []const std.MultiArrayList(renderpkg.RenderState.Cell),
    dirty: []bool,
};

/// C: GhosttyRenderState
pub const RenderState = ?*RenderStateWrapper;

/// C: GhosttyRenderStateRowIterator
pub const RowIterator = ?*RowIteratorWrapper;

/// C: GhosttyRenderStateDirty
pub const Dirty = renderpkg.RenderState.Dirty;

/// C: GhosttyRenderStateData
pub const Data = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    dirty = 3,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .invalid => void,
            .cols, .rows => size.CellCountInt,
            .dirty => Dirty,
        };
    }
};

/// C: GhosttyRenderStateOption
pub const SetOption = enum(c_int) {
    dirty = 0,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: SetOption) type {
        return switch (self) {
            .dirty => Dirty,
        };
    }
};

/// C: GhosttyRenderStateColors
pub const Colors = extern struct {
    size: usize = @sizeOf(Colors),
    background: colorpkg.RGB.C,
    foreground: colorpkg.RGB.C,
    cursor: colorpkg.RGB.C,
    cursor_has_value: bool,
    palette: [256]colorpkg.RGB.C,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *RenderState,
) callconv(.c) Result {
    result.* = new_(alloc_) catch |err| {
        result.* = null;
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn new_(alloc_: ?*const CAllocator) error{OutOfMemory}!*RenderStateWrapper {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(RenderStateWrapper) catch
        return error.OutOfMemory;
    ptr.* = .{ .alloc = alloc };
    return ptr;
}

pub fn free(state_: RenderState) callconv(.c) void {
    const state = state_ orelse return;
    const alloc = state.alloc;
    state.state.deinit(alloc);
    alloc.destroy(state);
}

pub fn update(
    state_: RenderState,
    terminal_: terminal_c.Terminal,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    const t = terminal_ orelse return .invalid_value;

    state.state.update(state.alloc, t) catch return .out_of_memory;
    return .success;
}

pub fn get(
    state_: RenderState,
    data: Data,
    out: ?*anyopaque,
) callconv(.c) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Data, @intFromEnum(data)) catch {
            log.warn("render_state_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        inline else => |comptime_data| getTyped(
            state_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    state_: RenderState,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const state = state_ orelse return .invalid_value;
    switch (data) {
        .invalid => return .invalid_value,
        .cols => out.* = state.state.cols,
        .rows => out.* = state.state.rows,
        .dirty => out.* = state.state.dirty,
    }

    return .success;
}

pub fn set(
    state_: RenderState,
    option: SetOption,
    value: ?*const anyopaque,
) callconv(.c) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(SetOption, @intFromEnum(option)) catch {
            log.warn("render_state_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| setTyped(
            state_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return .invalid_value)),
        ),
    };
}

fn setTyped(
    state_: RenderState,
    comptime option: SetOption,
    value: *const option.InType(),
) Result {
    const state = state_ orelse return .invalid_value;
    switch (option) {
        .dirty => state.state.dirty = value.*,
    }

    return .success;
}

pub fn colors_get(
    state_: RenderState,
    out_colors_: ?*Colors,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    const out_colors = out_colors_ orelse return .invalid_value;
    const out_size = out_colors.size;
    if (out_size < @sizeOf(usize)) return .invalid_value;

    const colors = state.state.colors;
    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "background",
    )) {
        out_colors.background = colors.background.cval();
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "foreground",
    )) {
        out_colors.foreground = colors.foreground.cval();
    }

    if (colors.cursor) |cursor| {
        if (lib.structSizedFieldFits(
            Colors,
            out_size,
            "cursor",
        )) {
            out_colors.cursor = cursor.cval();
        }
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "cursor_has_value",
    )) {
        out_colors.cursor_has_value = colors.cursor != null;
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "palette",
    )) {
        const palette_offset = @offsetOf(Colors, "palette");
        if (out_size > palette_offset) {
            const available = out_size - palette_offset;
            const max_entries = @min(colors.palette.len, available / @sizeOf(colorpkg.RGB.C));
            for (0..max_entries) |i| {
                out_colors.palette[i] = colors.palette[i].cval();
            }
        }
    }

    return .success;
}



pub fn row_iterator_new(
    alloc_: ?*const CAllocator,
    state_: RenderState,
    out_iterator_: ?*RowIterator,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    const out_iterator = out_iterator_ orelse return .invalid_value;
    const alloc = lib_alloc.default(alloc_);

    out_iterator.* = row_iterator_new_(
        alloc,
        state,
    ) catch |err| {
        out_iterator.* = null;
        switch (err) {
            error.OutOfMemory => return .out_of_memory,
        }
    };

    return .success;
}

fn row_iterator_new_(
    alloc: Allocator,
    state: *RenderStateWrapper,
) !*RowIteratorWrapper {
    const it = try alloc.create(RowIteratorWrapper);
    errdefer alloc.destroy(it);

    const row_data = state.state.row_data.slice();
    it.* = .{
        .alloc = alloc,
        .y = null,
        .raws = row_data.items(.raw),
        .cells = row_data.items(.cells),
        .dirty = row_data.items(.dirty),
    };

    return it;
}

pub fn row_iterator_free(iterator_: RowIterator) callconv(.c) void {
    const iterator = iterator_ orelse return;
    const alloc = iterator.alloc;
    alloc.destroy(iterator);
}

pub fn row_iterator_next(iterator_: RowIterator) callconv(.c) bool {
    const it = iterator_ orelse return false;
    const next_y: size.CellCountInt = if (it.y) |y| y + 1 else 0;
    if (next_y >= it.raws.len) return false;
    it.y = next_y;
    return true;
}

/// C: GhosttyRenderStateRowData
pub const RowData = enum(c_int) {
    invalid = 0,
    dirty = 1,
    raw = 2,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: RowData) type {
        return switch (self) {
            .invalid => void,
            .dirty => bool,
            .raw => row.CRow,
        };
    }
};

/// C: GhosttyRenderStateRowOption
pub const RowOption = enum(c_int) {
    dirty = 0,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: RowOption) type {
        return switch (self) {
            .dirty => bool,
        };
    }
};

pub fn row_get(
    iterator_: RowIterator,
    data: RowData,
    out: ?*anyopaque,
) callconv(.c) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(RowData, @intFromEnum(data)) catch {
            log.warn("render_state_row_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        inline else => |comptime_data| rowGetTyped(
            iterator_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn rowGetTyped(
    iterator_: RowIterator,
    comptime data: RowData,
    out: *data.OutType(),
) Result {
    const it = iterator_ orelse return .invalid_value;
    const y = it.y orelse return .invalid_value;
    switch (data) {
        .invalid => return .invalid_value,
        .dirty => out.* = it.dirty[y],
        .raw => out.* = it.raws[y].cval(),
    }

    return .success;
}

pub fn row_set(
    iterator_: RowIterator,
    option: RowOption,
    value: ?*const anyopaque,
) callconv(.c) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(RowOption, @intFromEnum(option)) catch {
            log.warn("render_state_row_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| rowSetTyped(
            iterator_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return .invalid_value)),
        ),
    };
}

fn rowSetTyped(
    iterator_: RowIterator,
    comptime option: RowOption,
    value: *const option.InType(),
) Result {
    const it = iterator_ orelse return .invalid_value;
    const y = it.y orelse return .invalid_value;
    switch (option) {
        .dirty => it.dirty[y] = value.*,
    }

    return .success;
}

test "render: new/free" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    try testing.expect(state != null);
    free(state);
}

test "render: free null" {
    free(null);
}

test "render: update invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, update(null, null));
    try testing.expectEqual(Result.invalid_value, update(state, null));
}

test "render: get invalid value" {
    var cols: size.CellCountInt = 0;
    try testing.expectEqual(Result.invalid_value, get(null, .cols, @ptrCast(&cols)));
}

test "render: get invalid data" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, get(state, .invalid, null));
}

test "render: colors get invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var colors: Colors = std.mem.zeroes(Colors);
    colors.size = @sizeOf(Colors);

    try testing.expectEqual(Result.invalid_value, colors_get(null, &colors));
    try testing.expectEqual(Result.invalid_value, colors_get(state, null));

    colors.size = @sizeOf(usize) - 1;
    try testing.expectEqual(Result.invalid_value, colors_get(state, &colors));
}

test "render: get/set dirty invalid value" {
    var dirty: Dirty = .false;
    try testing.expectEqual(Result.invalid_value, get(null, .dirty, @ptrCast(&dirty)));
    const dirty_full: Dirty = .full;
    try testing.expectEqual(Result.invalid_value, set(null, .dirty, @ptrCast(&dirty_full)));
}

test "render: get/set dirty" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var dirty: Dirty = undefined;
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.false, dirty);

    const dirty_partial: Dirty = .partial;
    try testing.expectEqual(Result.success, set(state, .dirty, @ptrCast(&dirty_partial)));
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.partial, dirty);

    const dirty_full: Dirty = .full;
    try testing.expectEqual(Result.success, set(state, .dirty, @ptrCast(&dirty_full)));
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.full, dirty);
}

test "render: set null value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, set(state, .dirty, null));
}

test "render: row iterator new invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.invalid_value, row_iterator_new(
        &lib_alloc.test_allocator,
        null,
        &iterator,
    ));
    try testing.expectEqual(Result.invalid_value, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        null,
    ));
}

test "render: row iterator new/free" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expect(iterator != null);
    const iterator_ptr = iterator.?;
    const row_data = state.?.state.row_data.slice();

    try testing.expectEqual(@as(?size.CellCountInt, null), iterator_ptr.y);
    try testing.expectEqual(row_data.items(.raw).len, iterator_ptr.raws.len);
    try testing.expectEqual(row_data.items(.cells).len, iterator_ptr.cells.len);
    try testing.expectEqual(row_data.items(.dirty).len, iterator_ptr.dirty.len);
}

test "render: row iterator free null" {
    row_iterator_free(null);
}

test "render: row iterator next null" {
    try testing.expect(!row_iterator_next(null));
}

test "render: row get null" {
    var dirty: bool = undefined;
    try testing.expectEqual(Result.invalid_value, row_get(null, .dirty, @ptrCast(&dirty)));
}

test "render: row get invalid data" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expect(row_iterator_next(iterator));
    try testing.expectEqual(Result.invalid_value, row_get(iterator, .invalid, null));
}

test "render: row set null" {
    const dirty = false;
    try testing.expectEqual(Result.invalid_value, row_set(null, .dirty, @ptrCast(&dirty)));
}

test "render: row set before iteration" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    const dirty = false;
    try testing.expectEqual(Result.invalid_value, row_set(iterator, .dirty, @ptrCast(&dirty)));
}

test "render: row get before iteration" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    var dirty: bool = undefined;
    try testing.expectEqual(Result.invalid_value, row_get(iterator, .dirty, @ptrCast(&dirty)));
}

test "render: row get/set dirty" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    // Dirty the first row so the iterator has at least one dirty row to observe.
    terminal_c.vt_write(terminal, "hello", 5);
    try testing.expectEqual(Result.success, update(state, terminal));

    // Create an iterator and verify it is dirty.
    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expect(row_iterator_next(it));
    var dirty: bool = undefined;
    try testing.expectEqual(Result.success, row_get(it, .dirty, @ptrCast(&dirty)));
    try testing.expect(dirty);

    // Clear dirty on this row.
    const dirty_false = false;
    try testing.expectEqual(Result.success, row_set(it, .dirty, @ptrCast(&dirty_false)));

    // It should not be dirty anymore.
    var it2: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        &it2,
    ));
    defer row_iterator_free(it2);

    try testing.expect(row_iterator_next(it2));
    try testing.expectEqual(Result.success, row_get(it2, .dirty, @ptrCast(&dirty)));
    try testing.expect(!dirty);
}

test "render: row iterator next" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    const rows = state.?.state.rows;
    if (rows == 0) {
        try testing.expect(!row_iterator_next(iterator));
        return;
    }

    try testing.expect(row_iterator_next(iterator));
    try testing.expectEqual(@as(?size.CellCountInt, 0), iterator.?.y);

    var i: size.CellCountInt = 1;
    while (i < rows) : (i += 1) {
        try testing.expect(row_iterator_next(iterator));
        try testing.expectEqual(@as(?size.CellCountInt, i), iterator.?.y);
    }

    try testing.expect(!row_iterator_next(iterator));
    try testing.expectEqual(@as(?size.CellCountInt, rows - 1), iterator.?.y);
}

test "render: update" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    terminal_c.vt_write(terminal, "hello", 5);
    try testing.expectEqual(Result.success, update(state, terminal));

    var cols: size.CellCountInt = 0;
    var rows_val: size.CellCountInt = 0;
    try testing.expectEqual(Result.success, get(state, .cols, @ptrCast(&cols)));
    try testing.expectEqual(Result.success, get(state, .rows, @ptrCast(&rows_val)));
    try testing.expectEqual(@as(size.CellCountInt, 80), cols);
    try testing.expectEqual(@as(size.CellCountInt, 24), rows_val);
}

test "render: colors get" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var colors: Colors = std.mem.zeroes(Colors);
    colors.size = @sizeOf(Colors);
    try testing.expectEqual(Result.success, colors_get(state, &colors));

    const state_colors = &state.?.state.colors;
    try testing.expectEqual(state_colors.background.cval(), colors.background);
    try testing.expectEqual(state_colors.foreground.cval(), colors.foreground);

    if (state_colors.cursor) |cursor| {
        try testing.expect(colors.cursor_has_value);
        try testing.expectEqual(cursor.cval(), colors.cursor);
    } else {
        try testing.expect(!colors.cursor_has_value);
    }

    for (state_colors.palette, colors.palette) |expected, actual| {
        try testing.expectEqual(expected.cval(), actual);
    }
}

test "render: colors get supports truncated sized struct" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var colors: Colors = std.mem.zeroes(Colors);
    const sentinel: colorpkg.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    for (&colors.palette) |*entry| entry.* = sentinel;

    colors.size = @offsetOf(Colors, "palette") + @sizeOf(colorpkg.RGB.C) * 2;
    try testing.expectEqual(Result.success, colors_get(state, &colors));

    const state_colors = &state.?.state.colors;
    try testing.expectEqual(state_colors.palette[0].cval(), colors.palette[0]);
    try testing.expectEqual(state_colors.palette[1].cval(), colors.palette[1]);
    try testing.expectEqual(sentinel, colors.palette[2]);
}
