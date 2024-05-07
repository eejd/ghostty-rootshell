const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const mtl_shaders = @import("shaders.zig");

/// The possible cell content keys that exist.
pub const Key = enum {
    bg,
    text,
    underline,
    strikethrough,

    /// Returns the GPU vertex type for this key.
    fn CellType(self: Key) type {
        return switch (self) {
            .bg => mtl_shaders.CellBg,

            .text,
            .underline,
            .strikethrough,
            => mtl_shaders.CellText,
        };
    }
};

/// A collection of ArrayLists with methods for bulk operations.
fn PooledArrayList(comptime T: type) type {
    return struct {
        pools: []std.ArrayListUnmanaged(T),

        pub fn init(alloc: Allocator, pool_count: usize) !PooledArrayList(T) {
            var self: PooledArrayList(T) = .{
                .pools = try alloc.alloc(std.ArrayListUnmanaged(T), pool_count),
            };

            for (self.pools) |*list| {
                list.* = .{};
            }

            self.reset();

            return self;
        }

        pub fn deinit(self: *PooledArrayList(T), alloc: Allocator) void {
            for (self.pools) |*list| {
                list.deinit(alloc);
            }
            alloc.free(self.pools);
        }

        /// Reset all pools to an empty state without freeing or resizing.
        pub fn reset(self: *PooledArrayList(T)) void {
            for (self.pools) |*list| {
                list.clearRetainingCapacity();
            }
        }

        /// Change the pool count and clear the contents of all pools.
        pub fn resize(self: *PooledArrayList(T), alloc: Allocator, pool_count: u16) !void {
            const pools  = try alloc.alloc(std.ArrayListUnmanaged(T), pool_count);
            errdefer alloc.free(pools);

            alloc.free(self.pools);

            self.pools = pools;

            for (self.pools) |*list| {
                list.* = .{};
            }

            self.reset();
        }
    };
}

/// The contents of all the cells in the terminal.
///
/// The goal of this data structure is to allow for efficient row-wise
/// clearing of data from the GPU buffers, to allow for row-wise dirty
/// tracking to eliminate the overhead of rebuilding the GPU buffers
/// each frame.
pub const Contents = struct {
    size: renderer.GridSize,

    bgs: PooledArrayList(mtl_shaders.CellBg),
    text: PooledArrayList(mtl_shaders.CellText),

    pub fn init(alloc: Allocator) !Contents {
        const result: Contents = .{
            .size = .{ .rows = 0, .columns = 0 },
            .bgs = try PooledArrayList(mtl_shaders.CellBg).init(alloc, 0),
            .text = try PooledArrayList(mtl_shaders.CellText).init(alloc, 0),
        };

        return result;
    }

    pub fn deinit(self: *Contents, alloc: Allocator) void {
        self.bgs.deinit(alloc);
        self.text.deinit(alloc);
    }

    /// Resize the cell contents for the given grid size. This will
    /// always invalidate the entire cell contents.
    pub fn resize(
        self: *Contents,
        alloc: Allocator,
        size: renderer.GridSize,
    ) !void {
        self.size = size;
        try self.bgs.resize(alloc, size.rows);
        try self.text.resize(alloc, size.rows + 1);

        // Make sure we don't have to allocate for the cursor cell.
        try self.text.pools[0].ensureTotalCapacity(alloc, 1);
    }

    /// Reset the cell contents to an empty state without resizing.
    pub fn reset(self: *Contents) void {
        self.bgs.reset();
        self.text.reset();
    }

    /// Set the cursor value. If the value is null then the cursor is hidden.
    pub fn setCursor(self: *Contents, v: ?mtl_shaders.CellText) void {
        self.text.pools[0].clearRetainingCapacity();

        if (v) |cell| {
            self.text.pools[0].appendAssumeCapacity(cell);
        }
    }

    /// Add a cell to the appropriate list. Adding the same cell twice will
    /// result in duplication in the vertex buffer. The caller should clear
    /// the corresponding row with Contents.clear to remove old cells first.
    pub fn add(
        self: *Contents,
        alloc: Allocator,
        comptime key: Key,
        cell: key.CellType(),
    ) !void {
        const y = cell.grid_pos[1];

        switch (key) {
            .bg
            => try self.bgs.pools[y].append(alloc, cell),

            .text,
            .underline,
            .strikethrough
            // We have a special pool containing the cursor cell at the start
            // of our text pool list, so we need to add 1 to the y to get the
            // correct index.
            => try self.text.pools[y + 1].append(alloc, cell),
        }
    }

    /// Clear all of the cell contents for a given row.
    pub fn clear(self: *Contents, y: terminal.size.CellCountInt) void {
        self.bgs.pools[y].clearRetainingCapacity();
        // We have a special pool containing the cursor cell at the start
        // of our text pool list, so we need to add 1 to the y to get the
        // correct index.
        self.text.pools[y + 1].clearRetainingCapacity();
    }
};

// test Contents {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//
//     const rows = 10;
//     const cols = 10;
//
//     var c = try Contents.init(alloc);
//     try c.resize(alloc, .{ .rows = rows, .columns = cols });
//     defer c.deinit(alloc);
//
//     // Assert that get returns null for everything.
//     for (0..rows) |y| {
//         for (0..cols) |x| {
//             try testing.expect(c.get(.bg, .{
//                 .x = @intCast(x),
//                 .y = @intCast(y),
//             }) == null);
//         }
//     }
//
//     // Set some contents
//     const cell: mtl_shaders.CellBg = .{
//         .mode = .rgb,
//         .grid_pos = .{ 4, 1 },
//         .cell_width = 1,
//         .color = .{ 0, 0, 0, 1 },
//     };
//     try c.set(alloc, .bg, cell);
//     try testing.expectEqual(cell, c.get(.bg, .{ .x = 4, .y = 1 }).?);
//
//     // Can clear it
//     c.clear(1);
//     for (0..rows) |y| {
//         for (0..cols) |x| {
//             try testing.expect(c.get(.bg, .{
//                 .x = @intCast(x),
//                 .y = @intCast(y),
//             }) == null);
//         }
//     }
// }

// test "Contents clear retains other content" {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//
//     const rows = 10;
//     const cols = 10;
//
//     var c = try Contents.init(alloc);
//     try c.resize(alloc, .{ .rows = rows, .columns = cols });
//     defer c.deinit(alloc);
//
//     // Set some contents
//     const cell1: mtl_shaders.CellBg = .{
//         .mode = .rgb,
//         .grid_pos = .{ 4, 1 },
//         .cell_width = 1,
//         .color = .{ 0, 0, 0, 1 },
//     };
//     const cell2: mtl_shaders.CellBg = .{
//         .mode = .rgb,
//         .grid_pos = .{ 4, 2 },
//         .cell_width = 1,
//         .color = .{ 0, 0, 0, 1 },
//     };
//     try c.set(alloc, .bg, cell1);
//     try c.set(alloc, .bg, cell2);
//     c.clear(1);
//
//     // Row 2 should still be valid.
//     try testing.expectEqual(cell2, c.get(.bg, .{ .x = 4, .y = 2 }).?);
// }

// test "Contents clear last added content" {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//
//     const rows = 10;
//     const cols = 10;
//
//     var c = try Contents.init(alloc);
//     try c.resize(alloc, .{ .rows = rows, .columns = cols });
//     defer c.deinit(alloc);
//
//     // Set some contents
//     const cell1: mtl_shaders.CellBg = .{
//         .mode = .rgb,
//         .grid_pos = .{ 4, 1 },
//         .cell_width = 1,
//         .color = .{ 0, 0, 0, 1 },
//     };
//     const cell2: mtl_shaders.CellBg = .{
//         .mode = .rgb,
//         .grid_pos = .{ 4, 2 },
//         .cell_width = 1,
//         .color = .{ 0, 0, 0, 1 },
//     };
//     try c.set(alloc, .bg, cell1);
//     try c.set(alloc, .bg, cell2);
//     c.clear(2);
//
//     // Row 2 should still be valid.
//     try testing.expectEqual(cell1, c.get(.bg, .{ .x = 4, .y = 1 }).?);
// }

// test "Contents clear modifies same data array" {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//
//     const rows = 10;
//     const cols = 10;
//
//     var c = try Contents.init(alloc);
//     try c.resize(alloc, .{ .rows = rows, .columns = cols });
//     defer c.deinit(alloc);
//
//     // Set some contents
//     const cell1: mtl_shaders.CellBg = .{
//         .mode = .rgb,
//         .grid_pos = .{ 4, 1 },
//         .cell_width = 1,
//         .color = .{ 0, 0, 0, 1 },
//     };
//     const cell2: mtl_shaders.CellBg = .{
//         .mode = .rgb,
//         .grid_pos = .{ 4, 2 },
//         .cell_width = 1,
//         .color = .{ 0, 0, 0, 1 },
//     };
//     try c.set(alloc, .bg, cell1);
//     try c.set(alloc, .bg, cell2);
//
//     const fg1: mtl_shaders.CellText = text: {
//         var cell: mtl_shaders.CellText = undefined;
//         cell.grid_pos = .{ 4, 1 };
//         break :text cell;
//     };
//     const fg2: mtl_shaders.CellText = text: {
//         var cell: mtl_shaders.CellText = undefined;
//         cell.grid_pos = .{ 4, 2 };
//         break :text cell;
//     };
//     try c.set(alloc, .text, fg1);
//     try c.set(alloc, .text, fg2);
//
//     c.clear(1);
//
//     // Should have all of row 2
//     try testing.expectEqual(cell2, c.get(.bg, .{ .x = 4, .y = 2 }).?);
//     try testing.expectEqual(fg2, c.get(.text, .{ .x = 4, .y = 2 }).?);
// }

test "Contents.Map size" {
    // We want to be mindful of when this increases because it affects
    // renderer memory significantly.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Contents.Map));
}
