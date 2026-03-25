/// Utilities for extending URL/link detection across non-soft-wrapped row
/// boundaries, such as tmux pane wrapping.
///
/// When terminal multiplexers like tmux render pane content, they use explicit
/// cursor positioning instead of letting text flow naturally. This means the
/// terminal never sets the `row.wrap` flag, and URLs that span multiple visual
/// rows appear as separate fragments on each row. These utilities detect
/// "logical windows" (column ranges bounded by box-drawing dividers or terminal
/// edges) and support extending regex matches across rows within a window.
const link_extend = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const page = @import("page.zig");
const size = @import("size.zig");
const point = @import("point.zig");
const url = @import("../config/url.zig");

/// A detected logical column window within the terminal grid.
/// Represents the content area between vertical dividers (or terminal edges).
pub const ColumnWindow = struct {
    /// The leftmost column of the content window (inclusive).
    left: size.CellCountInt,
    /// The rightmost column of the content window (inclusive).
    right: size.CellCountInt,
};

/// Returns true if the codepoint is a vertical box-drawing character
/// that could be a terminal multiplexer pane divider.
///
/// Only includes Unicode box-drawing characters. ASCII `|` is excluded
/// because it commonly appears in URLs, shell pipelines, and command output.
pub fn isVerticalDivider(cp: u21) bool {
    return switch (cp) {
        // Box Drawing vertical lines
        0x2502, // │ BOX DRAWINGS LIGHT VERTICAL
        0x2503, // ┃ BOX DRAWINGS HEAVY VERTICAL
        0x2506, // ┆ BOX DRAWINGS LIGHT TRIPLE DASH VERTICAL
        0x2507, // ┇ BOX DRAWINGS HEAVY TRIPLE DASH VERTICAL
        0x250A, // ┊ BOX DRAWINGS LIGHT QUADRUPLE DASH VERTICAL
        0x250B, // ┋ BOX DRAWINGS HEAVY QUADRUPLE DASH VERTICAL
        // Left T-junctions
        0x251C, // ├ BOX DRAWINGS LIGHT VERTICAL AND RIGHT
        0x251D, // ┝
        0x251E, // ┞
        0x251F, // ┟
        0x2520, // ┠
        0x2521, // ┡
        0x2522, // ┢
        0x2523, // ┣ BOX DRAWINGS HEAVY VERTICAL AND RIGHT
        // Right T-junctions
        0x2524, // ┤ BOX DRAWINGS LIGHT VERTICAL AND LEFT
        0x2525, // ┥
        0x2526, // ┦
        0x2527, // ┧
        0x2528, // ┨
        0x2529, // ┩
        0x252A, // ┪
        0x252B, // ┫ BOX DRAWINGS HEAVY VERTICAL AND LEFT
        // Crosses
        0x253C, // ┼ BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL
        0x253D, // ┽
        0x253E, // ┾
        0x253F, // ┿
        0x2540, // ╀
        0x2541, // ╁
        0x2542, // ╂
        0x2543, // ╃
        0x2544, // ╄
        0x2545, // ╅
        0x2546, // ╆
        0x2547, // ╇
        0x2548, // ╈
        0x2549, // ╉
        0x254A, // ╊
        0x254B, // ╋ BOX DRAWINGS HEAVY VERTICAL AND HORIZONTAL
        // Double-line variants
        0x2551, // ║ BOX DRAWINGS DOUBLE VERTICAL
        0x2560, // ╠ BOX DRAWINGS DOUBLE VERTICAL AND RIGHT
        0x2563, // ╣ BOX DRAWINGS DOUBLE VERTICAL AND LEFT
        0x256C, // ╬ BOX DRAWINGS DOUBLE VERTICAL AND HORIZONTAL
        // Mixed double/single junctions
        0x255E, // ╞ BOX DRAWINGS UP SINGLE AND RIGHT DOUBLE
        0x255F, // ╟ BOX DRAWINGS UP DOUBLE AND RIGHT SINGLE
        0x2561, // ╡ BOX DRAWINGS UP SINGLE AND LEFT DOUBLE
        0x2562, // ╢ BOX DRAWINGS UP DOUBLE AND LEFT SINGLE
        0x256A, // ╪ BOX DRAWINGS VERTICAL SINGLE AND HORIZONTAL DOUBLE
        0x256B, // ╫ BOX DRAWINGS VERTICAL DOUBLE AND HORIZONTAL SINGLE
        => true,
        else => false,
    };
}

/// Detect the logical column window around a given x position in a row.
///
/// Scans left and right from `x` to find vertical divider characters.
/// Returns the column range between dividers (or terminal edges).
/// The returned window excludes the divider columns themselves.
pub fn detectColumnWindow(
    cells: []const page.Cell,
    x: size.CellCountInt,
    total_cols: size.CellCountInt,
) ColumnWindow {
    const len = @min(cells.len, total_cols);

    // Scan left from x to find a divider or the terminal left edge.
    var left: size.CellCountInt = 0;
    if (x > 0) {
        var i: size.CellCountInt = x;
        while (i > 0) {
            i -= 1;
            if (isVerticalDivider(cells[i].codepoint())) {
                left = i + 1;
                break;
            }
        }
    }

    // Scan right from x to find a divider or the terminal right edge.
    var right: size.CellCountInt = @intCast(len -| 1);
    {
        var i: size.CellCountInt = x + 1;
        while (i < len) : (i += 1) {
            if (isVerticalDivider(cells[i].codepoint())) {
                right = i - 1;
                break;
            }
        }
    }

    return .{ .left = left, .right = right };
}

/// Check if a match ending at column `end_x` is at the right boundary
/// of the column window.
///
/// Returns true only if `end_x` is at or past `window.right`, meaning
/// the content genuinely fills the window to the right edge. This
/// indicates the text likely wrapped to the next row.
///
/// Note: trailing whitespace padding (as tmux adds) does NOT count as
/// being "at the boundary." A short line like "/tmp/foo" padded with
/// spaces to fill the pane width is NOT at the boundary.
pub fn isAtRightBoundary(
    cells: []const page.Cell,
    end_x: size.CellCountInt,
    window: ColumnWindow,
) bool {
    _ = cells;
    return end_x >= window.right;
}

/// Maximum number of rows to extend a match across.
pub const max_extend_rows: usize = 15;

/// Returns true if the text starts with a URL scheme (e.g., "https://",
/// "ftp://", "mailto:", etc.). Multi-row extension should only apply to
/// scheme-based URLs, not file path matches, because the path regex
/// branches are too broad and can stitch unrelated text across rows.
pub fn hasUrlScheme(text: []const u8) bool {
    for (url.scheme_prefixes) |scheme| {
        if (text.len >= scheme.len and
            std.ascii.eqlIgnoreCase(text[0..scheme.len], scheme)) return true;
    }
    return false;
}

/// Extract text from cells within a column window into a writer,
/// and optionally record coordinate mappings.
///
/// For each cell in [window.left .. window.right], writes the codepoint
/// (and any grapheme data) to the writer. Skips null (0) codepoints.
///
/// If `coord_map` is provided, appends one coordinate entry per UTF-8
/// byte written, mapping back to the viewport (x, y) position.
pub fn extractWindowText(
    writer: anytype,
    cells_raw: []const page.Cell,
    cells_grapheme: []const []const u21,
    window: ColumnWindow,
    y: u32,
    coord_map: ?struct {
        alloc: Allocator,
        map: *std.ArrayListUnmanaged(point.Coordinate),
    },
) !void {
    const end: size.CellCountInt = @min(window.right + 1, @as(size.CellCountInt, @intCast(cells_raw.len)));
    var x: size.CellCountInt = window.left;
    while (x < end) : (x += 1) {
        const cell = cells_raw[x];
        const cp = cell.codepoint();
        if (cp == 0) continue;

        // Write the main codepoint.
        var len: usize = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
        try writer.print("{u}", .{cp});

        // Write grapheme data if present.
        if (cell.hasGrapheme()) {
            for (cells_grapheme[x]) |gcp| {
                len += std.unicode.utf8CodepointSequenceLength(gcp) catch continue;
                try writer.print("{u}", .{gcp});
            }
        }

        // Record coordinate mapping.
        if (coord_map) |m| {
            try m.map.appendNTimes(m.alloc, .{
                .x = x,
                .y = y,
            }, len);
        }
    }
}

// ============================================================
// Tests
// ============================================================

test "isVerticalDivider" {
    const testing = std.testing;

    // Box-drawing vertical lines
    try testing.expect(isVerticalDivider(0x2502)); // │
    try testing.expect(isVerticalDivider(0x2503)); // ┃
    try testing.expect(isVerticalDivider(0x2551)); // ║

    // T-junctions
    try testing.expect(isVerticalDivider(0x251C)); // ├
    try testing.expect(isVerticalDivider(0x2524)); // ┤
    try testing.expect(isVerticalDivider(0x2523)); // ┣
    try testing.expect(isVerticalDivider(0x252B)); // ┫

    // Crosses
    try testing.expect(isVerticalDivider(0x253C)); // ┼
    try testing.expect(isVerticalDivider(0x254B)); // ╋

    // Double-line
    try testing.expect(isVerticalDivider(0x2560)); // ╠
    try testing.expect(isVerticalDivider(0x2563)); // ╣
    try testing.expect(isVerticalDivider(0x256C)); // ╬

    // NOT dividers
    try testing.expect(!isVerticalDivider('|')); // ASCII pipe
    try testing.expect(!isVerticalDivider(' '));
    try testing.expect(!isVerticalDivider('a'));
    try testing.expect(!isVerticalDivider(0x2500)); // ─ horizontal line
    try testing.expect(!isVerticalDivider(0x2550)); // ═ double horizontal
    try testing.expect(!isVerticalDivider(0));
}

test "detectColumnWindow no dividers" {
    const testing = std.testing;

    // 10 columns, no dividers — should return full width
    var cells: [10]page.Cell = undefined;
    for (&cells) |*c| c.* = page.Cell.init('a');

    const window = detectColumnWindow(&cells, 5, 10);
    try testing.expectEqual(@as(size.CellCountInt, 0), window.left);
    try testing.expectEqual(@as(size.CellCountInt, 9), window.right);
}

test "detectColumnWindow single divider" {
    const testing = std.testing;

    // 10 columns with divider at col 4: [a a a a │ a a a a a]
    var cells: [10]page.Cell = undefined;
    for (&cells) |*c| c.* = page.Cell.init('a');
    cells[4] = page.Cell.init(0x2502); // │

    // Click in right window (col 6)
    const right_window = detectColumnWindow(&cells, 6, 10);
    try testing.expectEqual(@as(size.CellCountInt, 5), right_window.left);
    try testing.expectEqual(@as(size.CellCountInt, 9), right_window.right);

    // Click in left window (col 2)
    const left_window = detectColumnWindow(&cells, 2, 10);
    try testing.expectEqual(@as(size.CellCountInt, 0), left_window.left);
    try testing.expectEqual(@as(size.CellCountInt, 3), left_window.right);
}

test "detectColumnWindow two dividers" {
    const testing = std.testing;

    // 15 columns with dividers at col 4 and col 10:
    // [a a a a │ a a a a a │ a a a a]
    var cells: [15]page.Cell = undefined;
    for (&cells) |*c| c.* = page.Cell.init('a');
    cells[4] = page.Cell.init(0x2502); // │
    cells[10] = page.Cell.init(0x2502); // │

    // Click in middle window (col 7)
    const mid_window = detectColumnWindow(&cells, 7, 15);
    try testing.expectEqual(@as(size.CellCountInt, 5), mid_window.left);
    try testing.expectEqual(@as(size.CellCountInt, 9), mid_window.right);
}

test "isAtRightBoundary exact" {
    const testing = std.testing;

    var cells: [10]page.Cell = undefined;
    for (&cells) |*c| c.* = page.Cell.init('a');

    const window: ColumnWindow = .{ .left = 0, .right = 9 };
    // End at last column — at boundary
    try testing.expect(isAtRightBoundary(&cells, 9, window));
    // End at col 5 with content after — not at boundary
    try testing.expect(!isAtRightBoundary(&cells, 5, window));
}

test "isAtRightBoundary trailing spaces not at boundary" {
    const testing = std.testing;

    // Content ends at col 5, cols 6-9 are spaces (tmux padding).
    // This is NOT at the boundary — the content didn't fill the window.
    var cells: [10]page.Cell = undefined;
    for (&cells, 0..) |*c, i| {
        if (i <= 5) {
            c.* = page.Cell.init('a');
        } else {
            c.* = page.Cell.init(' ');
        }
    }

    const window: ColumnWindow = .{ .left = 0, .right = 9 };
    try testing.expect(!isAtRightBoundary(&cells, 5, window));
}

test "isAtRightBoundary trailing nulls not at boundary" {
    const testing = std.testing;

    // Content ends at col 5, cols 6-9 are null (empty cells).
    // NOT at boundary.
    var cells: [10]page.Cell = undefined;
    for (&cells, 0..) |*c, i| {
        if (i <= 5) {
            c.* = page.Cell.init('a');
        } else {
            c.* = page.Cell.init(0);
        }
    }

    const window: ColumnWindow = .{ .left = 0, .right = 9 };
    try testing.expect(!isAtRightBoundary(&cells, 5, window));
}
