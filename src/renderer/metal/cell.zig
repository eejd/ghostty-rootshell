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

    /// Returns true if the two keys share the same data array.
    fn sharedData(self: Key, other: Key) bool {
        return switch (self) {
            inline else => |self_tag| switch (other) {
                inline else => |other_tag| self_tag.CellType() == other_tag.CellType(),
            },
        };
    }
};

/// The contents of all the cells in the terminal.
///
/// The goal of this data structure is to make it efficient for two operations:
///
///   1. Setting the contents of a cell by coordinate. More specifically,
///      we want to be efficient setting cell contents by row since we
///      will be doing row dirty tracking.
///
///   2. Syncing the contents of the CPU buffers to GPU buffers. This happens
///      every frame and should be as fast as possible.
///
/// To achieve this, the contents are stored in contiguous arrays by
/// GPU vertex type and we have an array of mappings indexed per row
/// that map to the index in the GPU vertex array that the content is at.
pub const Contents = struct {
    const Map = struct {
        /// The rows of index mappings are stored in a single contiguous array
        /// where the start of each row can be direct indexed by its y coord,
        /// and the used length of each row's section is stored separately.
        rows: []u32,

        /// The used length for each row.
        lens: []u16,

        /// The size of each row in the contiguous rows array.
        row_size: u16,

        pub fn init(alloc: Allocator, size: renderer.GridSize) !Map {
            var map: Map = .{
                .rows = try alloc.alloc(u32, size.columns * size.rows),
                .lens = try alloc.alloc(u16, size.rows),
                .row_size = size.columns,
            };

            map.reset();

            return map;
        }

        pub fn deinit(self: *Map, alloc: Allocator) void {
            alloc.free(self.rows);
            alloc.free(self.lens);
        }

        /// Clear all rows in this map.
        pub fn reset(self: *Map) void {
            @memset(self.lens, 0);
        }

        /// Add a mapped index to a row.
        pub fn add(self: *Map, row: u16, idx: u32) void {
            assert(row < self.lens.len);

            const start = self.row_size * row;
            assert(start < self.rows.len);

            // TODO: Currently this makes the assumption that a given row
            // will never contain more cells than it has columns. That
            // assumption is easily violated due to graphemes and multiple-
            // substitution opentype operations. Currently I've just capped
            // the length so that additional cells will overwrite the last
            // one once the row size is exceeded. A better behavior should
            // be decided upon, this one could cause issues.
            const len = @min(self.row_size - 1, self.lens[row]);
            assert(len < self.row_size);

            self.rows[start + len] = idx;
            self.lens[row] = len + 1;
        }

        /// Get a slice containing all the mappings for a given row.
        pub fn getRow(self: *Map, row: u16) []u32 {
            assert(row < self.lens.len);

            const start = self.row_size * row;
            assert(start < self.rows.len);

            return self.rows[start..][0..self.lens[row]];
        }

        /// Clear a given row by resetting its len.
        pub fn clearRow(self: *Map, row: u16) void {
            assert(row < self.lens.len);
            self.lens[row] = 0;
        }
    };

    /// The grid size of the terminal. This is used to determine the
    /// map array index from a coordinate.
    size: renderer.GridSize,

    /// The actual GPU data (on the CPU) for all the cells in the terminal.
    /// This only contains the cells that have content set. To determine
    /// if a cell has content set, we check the map.
    ///
    /// This data is synced to a buffer on every frame.
    bgs: std.ArrayListUnmanaged(mtl_shaders.CellBg),
    text: std.ArrayListUnmanaged(mtl_shaders.CellText),

    /// The map for the bg cells.
    bg_map: Map,
    /// The map for the text cells.
    tx_map: Map,
    /// The map for the underline cells.
    ul_map: Map,
    /// The map for the strikethrough cells.
    st_map: Map,

    /// True when the cursor should be rendered. This is managed by
    /// the setCursor method and should not be set directly.
    cursor: bool,

    /// The amount of text elements we reserve at the beginning for
    /// special elements like the cursor.
    const text_reserved_len = 1;

    pub fn init(alloc: Allocator) !Contents {
        var result: Contents = .{
            .size = .{ .rows = 0, .columns = 0 },
            .bgs = .{},
            .text = .{},
            .bg_map = try Map.init(alloc, .{ .rows = 0, .columns = 0 }),
            .tx_map = try Map.init(alloc, .{ .rows = 0, .columns = 0 }),
            .ul_map = try Map.init(alloc, .{ .rows = 0, .columns = 0 }),
            .st_map = try Map.init(alloc, .{ .rows = 0, .columns = 0 }),
            .cursor = false,
        };

        // We preallocate some amount of space for cell contents
        // we always have as a prefix. For now the current prefix
        // is length 1: the cursor.
        try result.text.ensureTotalCapacity(alloc, text_reserved_len);
        result.text.items.len = text_reserved_len;

        return result;
    }

    pub fn deinit(self: *Contents, alloc: Allocator) void {
        self.bgs.deinit(alloc);
        self.text.deinit(alloc);
        self.bg_map.deinit(alloc);
        self.tx_map.deinit(alloc);
        self.ul_map.deinit(alloc);
        self.st_map.deinit(alloc);
    }

    /// Resize the cell contents for the given grid size. This will
    /// always invalidate the entire cell contents.
    pub fn resize(
        self: *Contents,
        alloc: Allocator,
        size: renderer.GridSize,
    ) !void {
        self.size = size;
        self.bgs.clearAndFree(alloc);
        self.text.shrinkAndFree(alloc, text_reserved_len);

        self.bg_map.deinit(alloc);
        self.tx_map.deinit(alloc);
        self.ul_map.deinit(alloc);
        self.st_map.deinit(alloc);

        self.bg_map = try Map.init(alloc, size);
        self.tx_map = try Map.init(alloc, size);
        self.ul_map = try Map.init(alloc, size);
        self.st_map = try Map.init(alloc, size);
    }

    /// Reset the cell contents to an empty state without resizing.
    pub fn reset(self: *Contents) void {
        self.bgs.clearRetainingCapacity();
        self.text.shrinkRetainingCapacity(text_reserved_len);

        self.bg_map.reset();
        self.tx_map.reset();
        self.ul_map.reset();
        self.st_map.reset();
    }

    /// Returns the slice of fg cell contents to sync with the GPU.
    pub fn fgCells(self: *const Contents) []const mtl_shaders.CellText {
        const start: usize = if (self.cursor) 0 else 1;
        return self.text.items[start..];
    }

    /// Returns the slice of bg cell contents to sync with the GPU.
    pub fn bgCells(self: *const Contents) []const mtl_shaders.CellBg {
        return self.bgs.items;
    }

    /// Set the cursor value. If the value is null then the cursor
    /// is hidden.
    pub fn setCursor(self: *Contents, v: ?mtl_shaders.CellText) void {
        const cell = v orelse {
            self.cursor = false;
            return;
        };

        self.cursor = true;
        self.text.items[0] = cell;
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
        // Get our list of cells based on the key (comptime).
        const list = &@field(self, switch (key) {
            .bg => "bgs",
            .text, .underline, .strikethrough => "text",
        });

        // Add a new cell to the list.
        const idx: u32 = @intCast(list.items.len);
        try list.append(alloc, cell);

        // And to the appropriate mapping.
        self.getMap(key).add(cell.grid_pos[1], idx);
    }

    /// Clear all of the cell contents for a given row.
    pub fn clear(self: *Contents, y: terminal.size.CellCountInt) void {
        inline for (std.meta.fields(Key)) |field| {
            const key: Key = @enumFromInt(field.value);
            // Get our list of cells based on the key (comptime).
            const list = &@field(self, switch (key) {
                .bg => "bgs",
                .text, .underline, .strikethrough => "text",
            });

            const map = self.getMap(key);

            const start = y * map.row_size;

            // We iterate from the end of the row because this makes it more
            // likely that we remove from the end of the list, which results
            // in not having to re-map anything.
            while (map.lens[y] > 0) {
                map.lens[y] -= 1;
                const i = start + map.lens[y];
                const idx = map.rows[i];

                _ = list.swapRemove(idx);

                // If we took this cell off the end of the arraylist then
                // we won't need to re-map anything.
                if (idx == list.items.len) continue;

                const new = list.items[idx];
                const new_y = new.grid_pos[1];

                // The cell contents that were moved need to be remapped so
                // we don't lose track of them.
                switch (key) {
                    .bg => self.remapBgs(new_y, idx),
                    .text, .underline, .strikethrough => self.remapText(new_y, idx),
                }
            }
        }
    }

    fn remapText(self: *Contents, row: u16, idx: u32) void {
        for (self.tx_map.getRow(row)) |*new_idx| {
            if (new_idx.* == self.text.items.len) {
                new_idx.* = idx;
                return;
            }
        }
        for (self.ul_map.getRow(row)) |*new_idx| {
            if (new_idx.* == self.text.items.len) {
                new_idx.* = idx;
                return;
            }
        }
        for (self.st_map.getRow(row)) |*new_idx| {
            if (new_idx.* == self.text.items.len) {
                new_idx.* = idx;
                return;
            }
        }
    }

    fn remapBgs(self: *Contents, row: u16, idx: u32) void {
        for (self.bg_map.getRow(row)) |*new_idx| {
            if (new_idx.* == self.bgs.items.len) {
                new_idx.* = idx;
                return;
            }
        }
    }

    fn getMap(self: *Contents, key: Key) *Map {
        return switch (key) {
            .bg => &self.bg_map,
            .text => &self.tx_map,
            .underline => &self.ul_map,
            .strikethrough => &self.st_map,
        };
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
