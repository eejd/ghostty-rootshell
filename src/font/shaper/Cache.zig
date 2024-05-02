//! This structure caches the shaped cells for a given text run.
//!
//! At one point, shaping was the most expensive part of rendering text
//! (accounting for 96% of frame time on my machine). To speed it up, this
//! was introduced so that shaping results can be cached depending on the
//! run.
//!
//! The cache key is the text run. The text run builds its own hash value
//! based on the font, style, codepoint, etc. This just utilizes the hash that
//! the text run provides.
pub const Cache = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const lru = @import("../../lru.zig");

/// Our LRU is the run hash to the shaped cells.
const LRU = lru.AutoHashMap(u64, []font.shape.Cell);

/// The cache of shaped cells.
map: LRU,

pub fn init() Cache {
    // Note: this is very arbitrary. Increasing this number will increase
    // the cache hit rate, but also increase the memory usage. We should do
    // some more empirical testing to see what the best value is.
    const capacity = 1024;

    return .{ .map = LRU.init(capacity) };
}

pub fn deinit(self: *Cache, alloc: Allocator) void {
    var it = self.map.map.iterator();
    while (it.next()) |entry| alloc.free(entry.value_ptr.*.data.value);
    self.map.deinit(alloc);
}

/// Get the shaped cells for the given text run or null if they are not
/// in the cache.
pub fn get(self: *const Cache, run: font.shape.TextRun) ?[]const font.shape.Cell {
    return self.map.get(run.hash);
}

/// Insert the shaped cells for the given text run into the cache. The
/// cells will be duplicated.
pub fn put(
    self: *Cache,
    alloc: Allocator,
    run: font.shape.TextRun,
    cells: []const font.shape.Cell,
) Allocator.Error!void {
    const copy = try alloc.dupe(font.shape.Cell, cells);
    const gop = try self.map.getOrPut(alloc, run.hash);
    if (gop.evicted) |evicted| alloc.free(evicted.value);
    gop.value_ptr.* = copy;
}

test Cache {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = Cache.init();
    defer c.deinit(alloc);

    var run: font.shape.TextRun = undefined;
    run.hash = 1;
    try testing.expect(c.get(run) == null);
    try c.put(alloc, run, &.{
        .{ .x = 0, .glyph_index = 0 },
        .{ .x = 1, .glyph_index = 1 },
    });

    const actual = c.get(run).?;
    try testing.expect(actual.len == 2);
}
