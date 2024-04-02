const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Same as std.mem.copyForwards but prefers libc memmove if it is available
/// because it is generally much faster.
pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memmove(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        std.mem.copyForwards(T, dest, source);
    }
}

/// Same as @memcpy but prefers libc memcpy if it is available
/// because it is generally much faster.
pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memcpy(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        @memcpy(dest[0..source.len], source);
    }
}

/// Same as std.mem.rotate(T, items, 1) but more efficient by using memmove
/// and a tmp var for the single rotated item instead of 3 calls to reverse.
pub inline fn rotateOnce(comptime T: type, items: []T) void {
    const tmp = items[0];
    move(T, items[0 .. items.len - 1], items[1..items.len]);
    items[items.len - 1] = tmp;
}

extern "c" fn memcpy(*anyopaque, *const anyopaque, usize) *anyopaque;
extern "c" fn memmove(*anyopaque, *const anyopaque, usize) *anyopaque;
