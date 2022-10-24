const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../font/main.zig");

const log = std.log.scoped(.renderer_size);

/// The dimensions of a single "cell" in the terminal grid.
///
/// The dimensions are dependent on the current loaded set of font glyphs.
/// We calculate the width based on the widest character and the height based
/// on the height requirement for an underscore (the "lowest" -- visually --
/// character).
///
/// The units for the width and height are in world space. They have to
/// be normalized for any renderer implementation.
pub const CellSize = struct {
    width: f32,
    height: f32,

    /// Initialize the cell size information from a font group. This ensures
    /// that all renderers use the same cell sizing information for the same
    /// fonts.
    pub fn init(alloc: Allocator, group: *font.GroupCache) !CellSize {
        // Get our cell metrics based on a regular font ascii 'M'. Why 'M'?
        // Doesn't matter, any normal ASCII will do we're just trying to make
        // sure we use the regular font.
        const metrics = metrics: {
            const index = (try group.indexForCodepoint(alloc, 'M', .regular, .text)).?;
            const face = try group.group.faceFromIndex(index);
            break :metrics face.metrics;
        };
        log.debug("cell dimensions={}", .{metrics});

        return CellSize{
            .width = metrics.cell_width,
            .height = metrics.cell_height,
        };
    }
};

/// The dimensions of the screen that the grid is rendered to. This is the
/// terminal screen, so it is likely a subset of the window size. The dimensions
/// should be in pixels.
pub const ScreenSize = struct {
    width: u32,
    height: u32,
};

/// The dimensions of the grid itself, in rows/columns units.
pub const GridSize = struct {
    const Unit = u32;

    columns: Unit = 0,
    rows: Unit = 0,

    /// Initialize a grid size based on a screen and cell size.
    pub fn init(screen: ScreenSize, cell: CellSize) GridSize {
        var result: GridSize = undefined;
        result.update(screen, cell);
        return result;
    }

    /// Update the columns/rows for the grid based on the given screen and
    /// cell size.
    pub fn update(self: *GridSize, screen: ScreenSize, cell: CellSize) void {
        self.columns = @floatToInt(Unit, @intToFloat(f32, screen.width) / cell.width);
        self.rows = @floatToInt(Unit, @intToFloat(f32, screen.height) / cell.height);
    }
};

test "GridSize update exact" {
    const testing = std.testing;

    var grid: GridSize = .{};
    grid.update(.{
        .width = 100,
        .height = 40,
    }, .{
        .width = 5,
        .height = 10,
    });

    try testing.expectEqual(@as(GridSize.Unit, 20), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 4), grid.rows);
}

test "GridSize update rounding" {
    const testing = std.testing;

    var grid: GridSize = .{};
    grid.update(.{
        .width = 20,
        .height = 40,
    }, .{
        .width = 6,
        .height = 15,
    });

    try testing.expectEqual(@as(GridSize.Unit, 3), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 2), grid.rows);
}
