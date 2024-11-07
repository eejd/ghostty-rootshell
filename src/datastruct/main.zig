//! The datastruct package contains data structures or anything closely
//! related to data structures.

const blocking_queue = @import("blocking_queue.zig");
const cache_table = @import("cache_table.zig");
const circ_buf = @import("circ_buf.zig");
const segmented_pool = @import("segmented_pool.zig");

pub const lru = @import("lru.zig");
pub const BlockingQueue = blocking_queue.BlockingQueue;
pub const CacheTable = cache_table.CacheTable;
pub const CircBuf = circ_buf.CircBuf;
pub const SegmentedPool = segmented_pool.SegmentedPool;

test {
    @import("std").testing.refAllDecls(@This());
}
