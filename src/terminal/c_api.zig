// This is the C-ABI API for the terminal package. This isn't used
// by other Zig programs but by C or WASM interfacing.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Terminal = @import("main.zig").Terminal;

// The allocator that we want to use.
const alloc = if (builtin.target.isWasm())
    std.heap.page_allocator
else
    std.heap.c_allocator;

export fn terminal_new(cols: usize, rows: usize) ?*Terminal {
    const term = Terminal.init(alloc, cols, rows) catch return null;
    const result = alloc.create(Terminal) catch return null;
    result.* = term;
    return result;
}

export fn terminal_free(ptr: ?*Terminal) void {
    if (ptr) |v| {
        v.deinit(alloc);
        alloc.destroy(v);
    }
}
