const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const kitty_gfx = @import("../kitty/graphics_storage.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyKittyGraphics
pub const KittyGraphics = if (build_options.kitty_graphics)
    *kitty_gfx.ImageStorage
else
    *anyopaque;

/// C: GhosttyKittyGraphicsPlacementIterator
pub const PlacementIterator = ?*PlacementIteratorWrapper;

const PlacementMap = std.AutoHashMapUnmanaged(
    kitty_gfx.ImageStorage.PlacementKey,
    kitty_gfx.ImageStorage.Placement,
);

const PlacementIteratorWrapper = struct {
    alloc: std.mem.Allocator,
    inner: PlacementMap.Iterator = undefined,
    entry: ?PlacementMap.Entry = null,
};

/// C: GhosttyKittyGraphicsData
pub const Data = enum(c_int) {
    invalid = 0,
    placement_iterator = 1,

    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .invalid => void,
            .placement_iterator => PlacementIterator,
        };
    }
};

/// C: GhosttyKittyGraphicsPlacementData
pub const PlacementData = enum(c_int) {
    invalid = 0,
    image_id = 1,
    placement_id = 2,
    is_virtual = 3,
    x_offset = 4,
    y_offset = 5,
    source_x = 6,
    source_y = 7,
    source_width = 8,
    source_height = 9,
    columns = 10,
    rows = 11,
    z = 12,

    pub fn OutType(comptime self: PlacementData) type {
        return switch (self) {
            .invalid => void,
            .image_id, .placement_id => u32,
            .is_virtual => bool,
            .x_offset,
            .y_offset,
            .source_x,
            .source_y,
            .source_width,
            .source_height,
            .columns,
            .rows,
            => u32,
            .z => i32,
        };
    }
};

pub fn get(
    graphics_: KittyGraphics,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            graphics_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    graphics_: KittyGraphics,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const storage = graphics_;
    switch (data) {
        .invalid => return .invalid_value,
        .placement_iterator => {
            const it = out.* orelse return .invalid_value;
            it.* = .{
                .alloc = it.alloc,
                .inner = storage.placements.iterator(),
            };
        },
    }
    return .success;
}

pub fn placement_iterator_new(
    alloc_: ?*const CAllocator,
    out: *PlacementIterator,
) callconv(lib.calling_conv) Result {
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(PlacementIteratorWrapper) catch {
        out.* = null;
        return .out_of_memory;
    };
    ptr.* = .{ .alloc = alloc };
    out.* = ptr;
    return .success;
}

pub fn placement_iterator_free(iter_: PlacementIterator) callconv(lib.calling_conv) void {
    const iter = iter_ orelse return;
    iter.alloc.destroy(iter);
}

pub fn placement_iterator_next(iter_: PlacementIterator) callconv(lib.calling_conv) bool {
    if (comptime !build_options.kitty_graphics) return false;

    const iter = iter_ orelse return false;
    iter.entry = iter.inner.next() orelse return false;
    return true;
}

pub fn placement_get(
    iter_: PlacementIterator,
    data: PlacementData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| placementGetTyped(
            iter_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn placementGetTyped(
    iter_: PlacementIterator,
    comptime data: PlacementData,
    out: *data.OutType(),
) Result {
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;

    switch (data) {
        .invalid => return .invalid_value,
        .image_id => out.* = entry.key_ptr.image_id,
        .placement_id => out.* = entry.key_ptr.placement_id.id,
        .is_virtual => out.* = entry.value_ptr.location == .virtual,
        .x_offset => out.* = entry.value_ptr.x_offset,
        .y_offset => out.* = entry.value_ptr.y_offset,
        .source_x => out.* = entry.value_ptr.source_x,
        .source_y => out.* = entry.value_ptr.source_y,
        .source_width => out.* = entry.value_ptr.source_width,
        .source_height => out.* = entry.value_ptr.source_height,
        .columns => out.* = entry.value_ptr.columns,
        .rows => out.* = entry.value_ptr.rows,
        .z => out.* = entry.value_ptr.z,
    }

    return .success;
}

const testing = std.testing;
const terminal_c = @import("terminal.zig");

test "placement_iterator new/free" {
    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    try testing.expect(iter != null);
    placement_iterator_free(iter);
}

test "placement_iterator free null" {
    placement_iterator_free(null);
}

test "placement_iterator next on empty storage" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator, &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(!placement_iterator_next(iter));
}

test "placement_iterator get before next returns invalid" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator, &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    var image_id: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_get(iter, .image_id, @ptrCast(&image_id)));
}

test "placement_iterator with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator, &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
    ));
    defer terminal_c.free(t);

    // Transmit and display a 1x2 RGB image (image_id=1, placement_id=1).
    // a=T (transmit+display), t=d (direct), f=24 (RGB), i=1, p=1
    // s=1,v=2 (1x2 pixels), c=10,r=1 (10 cols, 1 row)
    // //////// = 8 base64 chars = 6 bytes = 1*2*3 RGB bytes
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    // Should have exactly one placement.
    try testing.expect(placement_iterator_next(iter));

    var image_id: u32 = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .image_id, @ptrCast(&image_id)));
    try testing.expectEqual(1, image_id);

    var placement_id: u32 = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .placement_id, @ptrCast(&placement_id)));
    try testing.expectEqual(1, placement_id);

    var is_virtual: bool = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .is_virtual, @ptrCast(&is_virtual)));
    try testing.expect(!is_virtual);

    // No more placements.
    try testing.expect(!placement_iterator_next(iter));
}

test "placement_iterator with multiple placements" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator, &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
    ));
    defer terminal_c.free(t);

    // Transmit image 1 then display it twice with different placement IDs.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display1 = "\x1b_Ga=p,i=1,p=1,c=10,r=1;\x1b\\";
    const display2 = "\x1b_Ga=p,i=1,p=2,c=5,r=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display1.ptr, display1.len);
    terminal_c.vt_write(t, display2.ptr, display2.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    // Count placements and collect image IDs.
    var count: usize = 0;
    var seen_p1 = false;
    var seen_p2 = false;
    while (placement_iterator_next(iter)) {
        count += 1;

        var image_id: u32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .image_id, @ptrCast(&image_id)));
        try testing.expectEqual(1, image_id);

        var placement_id: u32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .placement_id, @ptrCast(&placement_id)));
        if (placement_id == 1) seen_p1 = true;
        if (placement_id == 2) seen_p2 = true;
    }

    try testing.expectEqual(2, count);
    try testing.expect(seen_p1);
    try testing.expect(seen_p2);
}
