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

const log = std.log.scoped(.font_shaper_cache);

/// Our LRU is the run hash to the shaped cells.
const LRU = lru.AutoHashMap(u64, []font.shape.Cell);

/// This is the threshold of evictions at which point we reset
/// the LRU completely. This is a workaround for the issue that
/// Zig stdlib hashmap gets slower over time
/// (https://github.com/ziglang/zig/issues/17851).
///
/// The value is based on naive measuring on my local machine.
/// If someone has a better idea of what this value should be,
/// please let me know.
const evictions_threshold = 8192;

/// The cache of shaped cells.
map: LRU,

/// Keep track of the number of evictions. We use this to workaround
/// the issue that Zig stdlib hashmap gets slower over time
/// (https://github.com/ziglang/zig/issues/17851). When evictions
/// reaches a certain threshold, we reset the LRU.
evictions: std.math.IntFittingRange(0, evictions_threshold) = 0,

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
    if (gop.evicted) |evicted| {
        alloc.free(evicted.value);

        // See the doc comment on evictions_threshold for why we do this.
        self.evictions += 1;
        if (self.evictions >= evictions_threshold) {
            log.debug("resetting cache due to too many evictions", .{});
            // We need to put our value here so deinit can free
            gop.value_ptr.* = copy;
            self.clear(alloc);

            // We need to call put again because self is now a
            // different pointer value so our gop pointers are invalid.
            return try self.put(alloc, run, cells);
        }
    }
    gop.value_ptr.* = copy;
}

pub fn count(self: *const Cache) usize {
    return self.map.map.count();
}

fn clear(self: *Cache, alloc: Allocator) void {
    self.deinit(alloc);
    self.* = init();
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
