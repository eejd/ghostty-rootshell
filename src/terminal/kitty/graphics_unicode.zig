//! This file contains various logic and data for working with the
//! Kitty graphics protocol unicode placeholder, virtual placement feature.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const terminal = @import("../main.zig");

const log = std.log.scoped(.kitty_gfx);

/// Codepoint for the unicode placeholder character.
pub const placeholder: u21 = 0x10EEEE;

/// Returns an iterator that iterates over all of the virtual placements
/// in the given pin. If `limit` is provided, the iterator will stop
/// when it reaches that pin (inclusive). If `limit` is not provided,
/// the iterator will continue until the end of the page list.
pub fn placementIterator(
    pin: terminal.Pin,
    limit: ?terminal.Pin,
) PlacementIterator {
    var row_it = pin.rowIterator(.right_down, limit);
    const row = row_it.next();
    return .{ .row_it = row_it, .row = row };
}

/// Iterator over unicode virtual placements.
pub const PlacementIterator = struct {
    row_it: terminal.PageList.RowIterator,
    row: ?terminal.Pin,

    pub fn next(self: *PlacementIterator) ?Placement {
        while (self.row) |*row| {
            // Our current run. A run is always only a single row. This
            // assumption is built-in to our logic so if we want to change
            // this later we have to redo the logic; tests should cover;
            var run: ?IncompletePlacement = null;

            // A row must have graphemes to possibly have virtual placements
            // since virtual placements are done via diacritics.
            if (row.rowAndCell().row.grapheme) {
                // Iterate over our remaining cells and find one with a placeholder.
                const cells = row.cells(.right);
                for (cells, row.x..) |*cell, x| {
                    // "row" now points to the top-left pin of the placement.
                    // We need this temporary state to build our incomplete
                    // placement.
                    assert(@intFromPtr(row) == @intFromPtr(&self.row));
                    row.x = @intCast(x);

                    // If this cell doesn't have the placeholder, then we
                    // complete the run if we have it otherwise we just move
                    // on and keep searching.
                    if (cell.codepoint() != placeholder) {
                        if (run) |prev| return prev.complete();
                        continue;
                    }

                    // TODO: we need to support non-grapheme cells that just
                    // do continuations all the way through.
                    assert(cell.hasGrapheme());

                    // If we don't have a previous run, then we save this
                    // incomplete one, start a run, and move on.
                    const curr = IncompletePlacement.init(row, cell);
                    if (run) |*prev| {
                        // If we can't append, then we complete the previous
                        // run and return it.
                        if (!prev.append(&curr)) {
                            // Note: self.row is already updated due to the
                            // row pointer above. It points back at this same
                            // cell so we can continue the new placements from
                            // here.
                            return prev.complete();
                        }

                        // append is mutating so if we reached this point
                        // then prev has been updated.
                    } else {
                        run = curr;
                    }
                }
            }

            // We move to the next row no matter what
            self.row = self.row_it.next();

            // If we have a run, we complete it here.
            if (run) |prev| return prev.complete();
        }

        return null;
    }
};

/// A virtual placement in the terminal. This can represent more than
/// one cell if the cells combine to be a run.
pub const Placement = struct {
    /// The top-left pin of the placement. This can be used to get the
    /// screen x/y.
    pin: terminal.Pin,

    /// The image ID and placement ID for this virtual placement. The
    /// image ID is encoded in the fg color (plus optional a 8-bit high
    /// value in the 3rd diacritic). The placement ID is encoded in the
    /// underline color (optionally).
    image_id: u32,
    placement_id: u32,

    /// Starting row/col index for the image itself. This is the "fragment"
    /// of the image we want to show in this placement. This is 0-indexed.
    col: u32,
    row: u32,

    /// The width/height in cells of this placement.
    width: u32,
    height: u32,
};

/// IncompletePlacement is the placement information present in a single
/// cell. It is "incomplete" because the specification allows for missing
/// diacritics and so on that continue from previous valid placements.
const IncompletePlacement = struct {
    /// The pin of the cell that created this incomplete placement.
    pin: terminal.Pin,

    /// Lower 24 bits of the image ID. This is specified in the fg color
    /// and is always required.
    image_id_low: u24,

    /// Higher 8 bits of the image ID specified using the 3rd diacritic.
    /// This is optional.
    image_id_high: ?u8 = null,

    /// Placement ID is optionally specified in the underline color.
    placement_id: ?u24 = null,

    /// The row/col index for the image. These are 0-indexed. These
    /// are specified using diacritics. The row is first and the col
    /// is second. Both are optional. If not specified, they can continue
    /// a previous placement under certain conditions.
    row: ?u32 = null,
    col: ?u32 = null,

    /// Parse the incomplete placement information from a row and cell.
    ///
    /// The cell could be derived from the row but in our usage we already
    /// have the cell and we don't want to waste cycles recomputing it.
    pub fn init(
        row: *const terminal.Pin,
        cell: *const terminal.Cell,
    ) IncompletePlacement {
        assert(cell.codepoint() == placeholder);
        const style = row.style(cell);

        var result: IncompletePlacement = .{
            .pin = row.*,
            .image_id_low = colorToId(style.fg_color),
            .placement_id = placement_id: {
                const id = colorToId(style.underline_color);
                break :placement_id if (id != 0) id else null;
            },
        };

        // Try to decode all our diacritics. Any invalid diacritics are
        // treated as if they don't exist. This isn't explicitly specified
        // at the time of writing this but it appears to be how Kitty behaves.
        const cps: []const u21 = row.grapheme(cell) orelse &.{};
        if (cps.len > 0) {
            result.row = getIndex(cps[0]) orelse value: {
                log.warn("virtual placement with invalid row diacritic cp={X}", .{cps[0]});
                break :value null;
            };

            if (cps.len > 1) {
                result.col = getIndex(cps[1]) orelse value: {
                    log.warn("virtual placement with invalid col diacritic cp={X}", .{cps[1]});
                    break :value null;
                };

                if (cps.len > 2) {
                    const high_ = getIndex(cps[2]) orelse value: {
                        log.warn("virtual placement with invalid high diacritic cp={X}", .{cps[2]});
                        break :value null;
                    };

                    if (high_) |high| {
                        result.image_id_high = std.math.cast(
                            u8,
                            high,
                        ) orelse value: {
                            log.warn("virtual placement with invalid high diacritic cp={X} value={}", .{
                                cps[2],
                                high,
                            });
                            break :value null;
                        };
                    }

                    // Any additional diacritics are ignored.
                }
            }
        }

        return result;
    }

    /// Append this incomplete placement to an existing placement to
    /// create a run. This returns true if the placements are compatible
    /// and were combined. If this returns false, the other placement is
    /// unchanged.
    pub fn append(self: *IncompletePlacement, other: *const IncompletePlacement) bool {
        return self.canAppend(other);
    }

    fn canAppend(self: *const IncompletePlacement, other: *const IncompletePlacement) bool {
        if (self.image_id_low != other.image_id_low) return false;
        if (self.placement_id != other.placement_id) return false;
        return false;
    }

    /// Complete the incomplete placement to create a full placement.
    /// This creates a new placement that isn't continuous with any previous
    /// placements.
    ///
    /// The pin is the pin of the cell that created this incomplete placement.
    pub fn complete(self: *const IncompletePlacement) Placement {
        return .{
            .pin = self.pin,
            .image_id = image_id: {
                const low: u32 = @intCast(self.image_id_low);
                const high: u32 = @intCast(self.image_id_high orelse 0);
                break :image_id low | (high << 24);
            },

            .placement_id = self.placement_id orelse 0,
            .col = self.col orelse 0,
            .row = self.row orelse 0,
            .width = 1,
            .height = 1,
        };
    }

    /// Convert a style color to a Kitty image protocol ID. This works by
    /// taking the 24 most significant bits of the color, which lets it work
    /// for both palette and rgb-based colors.
    fn colorToId(c: terminal.Style.Color) u24 {
        // TODO: test this
        return switch (c) {
            .none => 0,
            .palette => |v| @intCast(v),
            .rgb => |rgb| rgb: {
                const r: u24 = @intCast(rgb.r);
                const g: u24 = @intCast(rgb.g);
                const b: u24 = @intCast(rgb.b);
                break :rgb (r << 16) | (g << 8) | b;
            },
        };
    }
};

/// Get the row/col index for a diacritic codepoint. These are 0-indexed.
fn getIndex(cp: u21) ?u32 {
    const idx = std.sort.binarySearch(u21, cp, diacritics, {}, (struct {
        fn order(context: void, lhs: u21, rhs: u21) std.math.Order {
            _ = context;
            return std.math.order(lhs, rhs);
        }
    }).order) orelse return null;
    return @intCast(idx);
}

/// These are the diacritics used with the Kitty graphics protocol
/// Unicode placement feature to specify the row/column for placement.
/// The index into the array determines the value.
///
/// This is derived from:
/// https://sw.kovidgoyal.net/kitty/_downloads/f0a0de9ec8d9ff4456206db8e0814937/rowcolumn-diacritics.txt
const diacritics: []const u21 = &.{
    0x0305,
    0x030D,
    0x030E,
    0x0310,
    0x0312,
    0x033D,
    0x033E,
    0x033F,
    0x0346,
    0x034A,
    0x034B,
    0x034C,
    0x0350,
    0x0351,
    0x0352,
    0x0357,
    0x035B,
    0x0363,
    0x0364,
    0x0365,
    0x0366,
    0x0367,
    0x0368,
    0x0369,
    0x036A,
    0x036B,
    0x036C,
    0x036D,
    0x036E,
    0x036F,
    0x0483,
    0x0484,
    0x0485,
    0x0486,
    0x0487,
    0x0592,
    0x0593,
    0x0594,
    0x0595,
    0x0597,
    0x0598,
    0x0599,
    0x059C,
    0x059D,
    0x059E,
    0x059F,
    0x05A0,
    0x05A1,
    0x05A8,
    0x05A9,
    0x05AB,
    0x05AC,
    0x05AF,
    0x05C4,
    0x0610,
    0x0611,
    0x0612,
    0x0613,
    0x0614,
    0x0615,
    0x0616,
    0x0617,
    0x0657,
    0x0658,
    0x0659,
    0x065A,
    0x065B,
    0x065D,
    0x065E,
    0x06D6,
    0x06D7,
    0x06D8,
    0x06D9,
    0x06DA,
    0x06DB,
    0x06DC,
    0x06DF,
    0x06E0,
    0x06E1,
    0x06E2,
    0x06E4,
    0x06E7,
    0x06E8,
    0x06EB,
    0x06EC,
    0x0730,
    0x0732,
    0x0733,
    0x0735,
    0x0736,
    0x073A,
    0x073D,
    0x073F,
    0x0740,
    0x0741,
    0x0743,
    0x0745,
    0x0747,
    0x0749,
    0x074A,
    0x07EB,
    0x07EC,
    0x07ED,
    0x07EE,
    0x07EF,
    0x07F0,
    0x07F1,
    0x07F3,
    0x0816,
    0x0817,
    0x0818,
    0x0819,
    0x081B,
    0x081C,
    0x081D,
    0x081E,
    0x081F,
    0x0820,
    0x0821,
    0x0822,
    0x0823,
    0x0825,
    0x0826,
    0x0827,
    0x0829,
    0x082A,
    0x082B,
    0x082C,
    0x082D,
    0x0951,
    0x0953,
    0x0954,
    0x0F82,
    0x0F83,
    0x0F86,
    0x0F87,
    0x135D,
    0x135E,
    0x135F,
    0x17DD,
    0x193A,
    0x1A17,
    0x1A75,
    0x1A76,
    0x1A77,
    0x1A78,
    0x1A79,
    0x1A7A,
    0x1A7B,
    0x1A7C,
    0x1B6B,
    0x1B6D,
    0x1B6E,
    0x1B6F,
    0x1B70,
    0x1B71,
    0x1B72,
    0x1B73,
    0x1CD0,
    0x1CD1,
    0x1CD2,
    0x1CDA,
    0x1CDB,
    0x1CE0,
    0x1DC0,
    0x1DC1,
    0x1DC3,
    0x1DC4,
    0x1DC5,
    0x1DC6,
    0x1DC7,
    0x1DC8,
    0x1DC9,
    0x1DCB,
    0x1DCC,
    0x1DD1,
    0x1DD2,
    0x1DD3,
    0x1DD4,
    0x1DD5,
    0x1DD6,
    0x1DD7,
    0x1DD8,
    0x1DD9,
    0x1DDA,
    0x1DDB,
    0x1DDC,
    0x1DDD,
    0x1DDE,
    0x1DDF,
    0x1DE0,
    0x1DE1,
    0x1DE2,
    0x1DE3,
    0x1DE4,
    0x1DE5,
    0x1DE6,
    0x1DFE,
    0x20D0,
    0x20D1,
    0x20D4,
    0x20D5,
    0x20D6,
    0x20D7,
    0x20DB,
    0x20DC,
    0x20E1,
    0x20E7,
    0x20E9,
    0x20F0,
    0x2CEF,
    0x2CF0,
    0x2CF1,
    0x2DE0,
    0x2DE1,
    0x2DE2,
    0x2DE3,
    0x2DE4,
    0x2DE5,
    0x2DE6,
    0x2DE7,
    0x2DE8,
    0x2DE9,
    0x2DEA,
    0x2DEB,
    0x2DEC,
    0x2DED,
    0x2DEE,
    0x2DEF,
    0x2DF0,
    0x2DF1,
    0x2DF2,
    0x2DF3,
    0x2DF4,
    0x2DF5,
    0x2DF6,
    0x2DF7,
    0x2DF8,
    0x2DF9,
    0x2DFA,
    0x2DFB,
    0x2DFC,
    0x2DFD,
    0x2DFE,
    0x2DFF,
    0xA66F,
    0xA67C,
    0xA67D,
    0xA6F0,
    0xA6F1,
    0xA8E0,
    0xA8E1,
    0xA8E2,
    0xA8E3,
    0xA8E4,
    0xA8E5,
    0xA8E6,
    0xA8E7,
    0xA8E8,
    0xA8E9,
    0xA8EA,
    0xA8EB,
    0xA8EC,
    0xA8ED,
    0xA8EE,
    0xA8EF,
    0xA8F0,
    0xA8F1,
    0xAAB0,
    0xAAB2,
    0xAAB3,
    0xAAB7,
    0xAAB8,
    0xAABE,
    0xAABF,
    0xAAC1,
    0xFE20,
    0xFE21,
    0xFE22,
    0xFE23,
    0xFE24,
    0xFE25,
    0xFE26,
    0x10A0F,
    0x10A38,
    0x1D185,
    0x1D186,
    0x1D187,
    0x1D188,
    0x1D189,
    0x1D1AA,
    0x1D1AB,
    0x1D1AC,
    0x1D1AD,
    0x1D242,
    0x1D243,
    0x1D244,
};

test "unicode diacritic sorted" {
    // diacritics must be sorted since we use a binary search.
    try testing.expect(std.sort.isSorted(u21, diacritics, {}, (struct {
        fn lessThan(context: void, lhs: u21, rhs: u21) bool {
            _ = context;
            return lhs < rhs;
        }
    }).lessThan));
}

test "unicode diacritic" {
    // Some spot checks based on Kitty behavior
    try testing.expectEqual(30, getIndex(0x483).?);
    try testing.expectEqual(294, getIndex(0x1d242).?);
}

test "unicode placement: none" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);

    // Single cell
    try t.printString("hello\nworld\n1\n2");

    // No placements
    const pin = t.screen.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    try testing.expect(it.next() == null);
}

test "unicode placement: single row/col" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);

    // Single cell
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");

    // Get our top left pin
    const pin = t.screen.pages.getTopLeft(.viewport);

    // Should have exactly one placement
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
    }
    try testing.expect(it.next() == null);
}

test "unicode placement: specifying image id as palette" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);

    // Single cell
    try t.setAttribute(.{ .@"256_fg" = 42 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");

    // Get our top left pin
    const pin = t.screen.pages.getTopLeft(.viewport);

    // Should have exactly one placement
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(42, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
    }
    try testing.expect(it.next() == null);
}

test "unicode placement: specifying image id with high bits" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);

    // Single cell
    try t.setAttribute(.{ .@"256_fg" = 42 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}\u{030E}");

    // Get our top left pin
    const pin = t.screen.pages.getTopLeft(.viewport);

    // Should have exactly one placement
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(33554474, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
    }
    try testing.expect(it.next() == null);
}

test "unicode placement: specifying placement id as palette" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);

    // Single cell
    try t.setAttribute(.{ .@"256_fg" = 42 });
    try t.setAttribute(.{ .@"256_underline_color" = 21 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");

    // Get our top left pin
    const pin = t.screen.pages.getTopLeft(.viewport);

    // Should have exactly one placement
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(42, p.image_id);
        try testing.expectEqual(21, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
    }
    try testing.expect(it.next() == null);
}
