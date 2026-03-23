const std = @import("std");
const testing = std.testing;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;

/// Free memory that was allocated by a libghostty-vt function.
///
/// This must be used to free buffers returned by functions like
/// `format_alloc`. Pass the same allocator (or NULL for the default)
/// that was used for the allocation.
pub fn free(
    alloc_: ?*const CAllocator,
    ptr: ?[*]u8,
    len: usize,
) callconv(.c) void {
    const mem = ptr orelse return;
    const alloc = lib_alloc.default(alloc_);
    alloc.free(mem[0..len]);
}

test "free null pointer" {
    free(&lib_alloc.test_allocator, null, 0);
}

test "free allocated memory" {
    const alloc = lib_alloc.default(&lib_alloc.test_allocator);
    const mem = try alloc.alloc(u8, 16);
    free(&lib_alloc.test_allocator, mem.ptr, mem.len);
}

test "free with null allocator" {
    // null allocator falls back to the default (test allocator in tests)
    const alloc = lib_alloc.default(null);
    const mem = try alloc.alloc(u8, 8);
    free(null, mem.ptr, mem.len);
}
