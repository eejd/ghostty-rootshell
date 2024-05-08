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

/// A pool of ArrayLists with methods for bulk operations.
fn ArrayListPool(comptime T: type) type {
    return struct {
        const Self = ArrayListPool(T);
        const ArrayListT = std.ArrayListUnmanaged(T);

        // An array containing the lists that belong to this pool.
        lists: []ArrayListT = &[_]ArrayListT{},

        // The pool will be initialized with empty ArrayLists.
        pub fn init(alloc: Allocator, list_count: usize, initial_capacity: usize) !Self {
            const self: Self = .{
                .lists = try alloc.alloc(ArrayListT, list_count),
            };

            for (self.lists) |*list| {
                list.* = try ArrayListT.initCapacity(alloc, initial_capacity);
            }

            return self;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.lists) |*list| {
                list.deinit(alloc);
            }
            alloc.free(self.lists);
        }

        /// Clear all lists in the pool.
        pub fn reset(self: *Self) void {
            for (self.lists) |*list| {
                list.clearRetainingCapacity();
            }
        }
    };
}

/// The contents of all the cells in the terminal.
///
/// The goal of this data structure is to allow for efficient row-wise
/// clearing of data from the GPU buffers, to allow for row-wise dirty
/// tracking to eliminate the overhead of rebuilding the GPU buffers
/// each frame.
///
/// Must be initialized by resizing before calling any operations.
pub const Contents = struct {
    size: renderer.GridSize = .{ .rows = 0, .columns = 0 },

    /// The ArrayListPool which holds all of the background cells. When sized
    /// with Contents.resize the individual ArrayLists SHOULD be given enough
    /// capacity that appendAssumeCapacity may be used, since it should be
    /// impossible for a row to have more background cells than columns.
    ///
    /// HOWEVER, the initial capacity can be exceeded due to multi-glyph
    /// composites each adding a background cell for the same position.
    /// This should probably be considered a bug, but for now it means
    /// that sometimes allocations might happen, so appendAssumeCapacity
    /// MUST NOT be used.
    ///
    /// Rows are indexed as Contents.bg_rows[y].
    ///
    /// Must be initialized by calling resize on the Contents struct before
    /// calling any operations.
    bg_rows: ArrayListPool(mtl_shaders.CellBg) = .{},

    /// The ArrayListPool which holds all of the foreground cells. When sized
    /// with Contents.resize the individual ArrayLists are given enough room
    /// that they can hold a single row with #cols glyphs, underlines, and
    /// strikethroughs; however, appendAssumeCapacity MUST NOT be used since
    /// it is possible to exceed this with combining glyphs that add a glyph
    /// but take up no column since they combine with the previous one, as
    /// well as with fonts that perform multi-substitutions for glyphs, which
    /// can result in a similar situation where multiple glyphs reside in the
    /// same column.
    ///
    /// Allocations should nevertheless be exceedingly rare since hitting the
    /// initial capacity of a list would require a row filled with underlined
    /// struck through characters, at least one of which is a multi-glyph
    /// composite.
    ///
    /// Rows are indexed as Contents.fg_rows[y + 1], because the first list in
    /// the pool is reserved for the cursor, which must be the first item in
    /// the buffer.
    ///
    /// Must be initialized by calling resize on the Contents struct before
    /// calling any operations.
    fg_rows: ArrayListPool(mtl_shaders.CellText) = .{},

    pub fn deinit(self: *Contents, alloc: Allocator) void {
        self.bg_rows.deinit(alloc);
        self.fg_rows.deinit(alloc);
    }

    /// Resize the cell contents for the given grid size. This will
    /// always invalidate the entire cell contents.
    pub fn resize(
        self: *Contents,
        alloc: Allocator,
        size: renderer.GridSize,
    ) !void {
        self.size = size;

        // When we create our bg_rows pool, we give the lists an initial
        // capacity of size.columns. This is to account for the usual case
        // where you have a row with normal text and background colors.
        // This can be exceeded due to multi-glyph composites each adding
        // a background cell for the same position. This should probably be
        // considered a bug, but for now it means that sometimes allocations
        // might happen, and appendAssumeCapacity MUST NOT be used.
        var bg_rows = try ArrayListPool(mtl_shaders.CellBg).init(alloc, size.rows, size.columns);
        errdefer bg_rows.deinit(alloc);

        // The foreground lists can hold 3 types of items:
        // - Glyphs
        // - Underlines
        // - Strikethroughs
        // So we give them an initial capacity of size.columns * 3, which will
        // avoid any further allocations in the vast majority of cases. Sadly
        // we can not assume capacity though, since with combining glyphs that
        // form a single grapheme, and multi-substitutions in fonts, the number
        // of glyphs in a row is theoretically unlimited.
        //
        // We have size.rows + 1 lists because index 0 is used for a special
        // list containing the cursor cell which needs to be first in the buffer.
        var fg_rows = try ArrayListPool(mtl_shaders.CellText).init(alloc, size.rows + 1, size.columns * 3);
        errdefer fg_rows.deinit(alloc);

        self.bg_rows.deinit(alloc);
        self.fg_rows.deinit(alloc);

        self.bg_rows = bg_rows;
        self.fg_rows = fg_rows;

        // We don't need 3*cols worth of cells for the cursor list, so we can
        // replace it with a smaller list. This is technically a tiny bit of
        // extra work but resize is not a hot function so it's worth it to not
        // waste the memory.
        self.fg_rows.lists[0].deinit(alloc);
        self.fg_rows.lists[0] = try std.ArrayListUnmanaged(mtl_shaders.CellText).initCapacity(alloc, 1);
    }

    /// Reset the cell contents to an empty state without resizing.
    pub fn reset(self: *Contents) void {
        self.bg_rows.reset();
        self.fg_rows.reset();
    }

    /// Set the cursor value. If the value is null then the cursor is hidden.
    pub fn setCursor(self: *Contents, v: ?mtl_shaders.CellText) void {
        self.fg_rows.lists[0].clearRetainingCapacity();

        if (v) |cell| {
            self.fg_rows.lists[0].appendAssumeCapacity(cell);
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
            => try self.bg_rows.lists[y].append(alloc, cell),

            .text,
            .underline,
            .strikethrough
            // We have a special list containing the cursor cell at the start
            // of our fg row pool, so we need to add 1 to the y to get the
            // correct index.
            => try self.fg_rows.lists[y + 1].append(alloc, cell),
        }
    }

    /// Clear all of the cell contents for a given row.
    pub fn clear(self: *Contents, y: terminal.size.CellCountInt) void {
        self.bg_rows.lists[y].clearRetainingCapacity();
        // We have a special list containing the cursor cell at the start
        // of our fg row pool, so we need to add 1 to the y to get the
        // correct index.
        self.fg_rows.lists[y + 1].clearRetainingCapacity();
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
