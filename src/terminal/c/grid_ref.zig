const std = @import("std");
const testing = std.testing;
const page = @import("../page.zig");
const PageList = @import("../PageList.zig");
const size = @import("../size.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyGridRef
///
/// A sized struct that holds a reference to a position in the terminal grid.
/// The ref points to a specific cell position within the terminal's
/// internal page structure.
pub const CGridRef = extern struct {
    size: usize = @sizeOf(CGridRef),
    node: ?*PageList.List.Node = null,
    x: size.CellCountInt = 0,
    y: size.CellCountInt = 0,

    pub fn fromPin(pin: PageList.Pin) CGridRef {
        return .{
            .node = pin.node,
            .x = pin.x,
            .y = pin.y,
        };
    }

    fn toPin(self: CGridRef) ?PageList.Pin {
        return .{
            .node = self.node orelse return null,
            .x = self.x,
            .y = self.y,
        };
    }
};

pub fn grid_ref_cell(
    ref: *const CGridRef,
    out: ?*cell_c.CCell,
) callconv(.c) Result {
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| o.* = @bitCast(p.rowAndCell().cell.*);
    return .success;
}

pub fn grid_ref_row(
    ref: *const CGridRef,
    out: ?*row_c.CRow,
) callconv(.c) Result {
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| o.* = @bitCast(p.rowAndCell().row.*);
    return .success;
}

test "grid_ref_cell null node" {
    const ref = CGridRef{};
    var out: cell_c.CCell = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_cell(&ref, &out));
}

test "grid_ref_row null node" {
    const ref = CGridRef{};
    var out: row_c.CRow = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_row(&ref, &out));
}

test "grid_ref_cell null out" {
    const ref = CGridRef{};
    try testing.expectEqual(Result.invalid_value, grid_ref_cell(&ref, null));
}

test "grid_ref_row null out" {
    const ref = CGridRef{};
    try testing.expectEqual(Result.invalid_value, grid_ref_row(&ref, null));
}
