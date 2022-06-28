const Screen = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const color = @import("color.zig");

const log = std.log.scoped(.screen);

/// A row is a set of cells.
pub const Row = []Cell;

/// Cell is a single cell within the screen.
pub const Cell = struct {
    /// Each cell contains exactly one character. The character is UTF-32
    /// encoded (just the Unicode codepoint).
    char: u32,

    /// Foreground and background color. null means to use the default.
    fg: ?color.RGB = null,
    bg: ?color.RGB = null,

    /// On/off attributes that can be set
    /// TODO: pack it
    attrs: struct {
        bold: u1 = 0,
        inverse: u1 = 0,
    } = .{},

    /// True if the cell should be skipped for drawing
    pub fn empty(self: Cell) bool {
        return self.char == 0;
    }
};

pub const RowIterator = struct {
    screen: *const Screen,
    index: usize,

    pub fn next(self: *RowIterator) ?Row {
        if (self.index >= self.screen.rows) return null;
        const res = self.screen.getRow(self.index);
        self.index += 1;
        return res;
    }
};

/// The full list of rows, including any scrollback.
storage: []Cell,

/// The first visible row.
zero: usize,

/// The number of rows and columns in the visible space.
rows: usize,
cols: usize,

/// Initialize a new screen.
pub fn init(alloc: Allocator, rows: usize, cols: usize) !Screen {
    // Allocate enough storage to cover every row and column in the visible
    // area. This wastes some up front memory but saves allocations later.
    const buf = try alloc.alloc(Cell, rows * cols);
    std.mem.set(Cell, buf, .{ .char = 0 });

    return Screen{
        .storage = buf,
        .zero = 0,
        .rows = rows,
        .cols = cols,
    };
}

pub fn deinit(self: *Screen, alloc: Allocator) void {
    alloc.free(self.storage);
    self.* = undefined;
}

/// Returns an iterator that can be used to iterate over all of the rows
/// from index zero.
pub fn rowIterator(self: *const Screen) RowIterator {
    return .{ .screen = self, .index = 0 };
}

/// Get the visible portion of the screen.
pub fn getVisible(self: Screen) []Cell {
    return self.storage;
}

/// Get a single row by index (0-indexed).
pub fn getRow(self: Screen, idx: usize) Row {
    // Get the index of the first byte of the the row at index.
    const real_idx = self.rowIndex(idx);

    // The storage is sliced to return exactly the number of columns.
    return self.storage[real_idx .. real_idx + self.cols];
}

/// Get a single cell in the visible area. row and col are 0-indexed.
pub fn getCell(self: Screen, row: usize, col: usize) *Cell {
    assert(row < self.rows);
    assert(col < self.cols);
    const row_idx = self.rowIndex(row);
    return &self.storage[row_idx + col];
}

/// Returns the index for the given row (0-indexed) into the underlying
/// storage array.
pub fn rowIndex(self: Screen, idx: usize) usize {
    assert(idx < self.rows);
    const val = (self.zero + idx) * self.cols;
    if (val < self.storage.len) return val;
    return val - self.storage.len;
}

/// Scroll the screen up (positive) or down (negative). Scrolling direction
/// is the direction text would move. For example, scrolling down would
/// move existing text downward.
pub fn scroll(self: *Screen, count: isize) void {
    if (count < 0) {
        const amount = @mod(@intCast(usize, -count), self.rows);
        if (amount > self.zero) {
            self.zero = self.rows - amount;
        } else {
            self.zero -|= amount;
        }
    } else {
        self.zero = @mod(self.zero + @intCast(usize, count), self.rows);
    }
}

/// Copy row at src to dst.
pub fn copyRow(self: *Screen, dst: usize, src: usize) void {
    const src_row = self.getRow(src);
    const dst_row = self.getRow(dst);
    std.mem.copy(Cell, dst_row, src_row);
}

/// Resize the screen. The rows or cols can be bigger or smaller. Due to
/// the internal representation of a screen, this usually involves a significant
/// amount of copying compared to any other operations.
///
/// This will trim data if the size is getting smaller. It is expected that
/// callers will reflow the text prior to calling this.
pub fn resize(self: *Screen, alloc: Allocator, rows: usize, cols: usize) !void {
    // Make a copy so we can access the old indexes.
    const old = self.*;

    // Reallocate the storage
    self.storage = try alloc.alloc(Cell, rows * cols);
    self.zero = 0;
    self.rows = rows;
    self.cols = cols;

    // If we're increasing height, then copy all rows (start at 0).
    // Otherwise start at the latest row that includes the bottom row,
    // aka trip the top.
    var y: usize = if (rows >= old.rows) 0 else old.rows - rows;
    const start = y;
    const col_end = @minimum(old.cols, cols);
    while (y < old.rows) : (y += 1) {
        // Copy the old row into the new row, just losing the columsn
        // if we got thinner.
        const old_row = old.getRow(y);
        const new_row = self.getRow(y - start);
        std.mem.copy(Cell, new_row, old_row[0..col_end]);

        // If our new row is wider, then we copy zeroes into the rest.
        if (new_row.len > old_row.len) {
            std.mem.set(Cell, new_row[old_row.len..], .{ .char = 0 });
        }
    }

    // If we grew rows, then set the remaining data to zero.
    if (rows > old.rows) {
        std.mem.set(Cell, self.storage[self.rowIndex(old.rows)..], .{ .char = 0 });
    }

    // Free the old data
    alloc.free(old.storage);
}

/// Turns the screen into a string.
pub fn testString(self: Screen, alloc: Allocator) ![]const u8 {
    const buf = try alloc.alloc(u8, self.storage.len + self.rows);

    var i: usize = 0;
    var y: usize = 0;
    var rows = self.rowIterator();
    while (rows.next()) |row| {
        defer y += 1;

        if (y > 0) {
            buf[i] = '\n';
            i += 1;
        }

        for (row) |cell| {
            // TODO: handle character after null
            if (cell.char > 0) {
                i += try std.unicode.utf8Encode(@intCast(u21, cell.char), buf[i..]);
            }
        }
    }

    // Never render the final newline
    const str = std.mem.trimRight(u8, buf[0..i], "\n");
    return try alloc.realloc(buf, str.len);
}

/// Writes a basic string into the screen for testing. Newlines (\n) separate
/// each row.
fn testWriteString(self: *Screen, text: []const u8) void {
    var y: usize = 0;
    var x: usize = 0;
    var row = self.getRow(y);
    for (text) |c| {
        if (c == '\n') {
            y += 1;
            x = 0;
            row = self.getRow(y);
            continue;
        }

        assert(x < self.cols);
        row[x].char = @intCast(u32, c);
        x += 1;
    }
}

test "Screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5);
    defer s.deinit(alloc);

    // Sanity check that our test helpers work
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    var contents = try s.testString(alloc);
    defer alloc.free(contents);
    try testing.expectEqualStrings(str, contents);

    // Test the row iterator
    var count: usize = 0;
    var iter = s.rowIterator();
    while (iter.next()) |row| {
        // Rows should be pointer equivalent to getRow
        const row_other = s.getRow(count);
        try testing.expectEqual(row.ptr, row_other.ptr);
        count += 1;
    }

    // Should go through all rows
    try testing.expectEqual(@as(usize, 3), count);
}

test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5);
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(1);

    // Test our row index
    try testing.expectEqual(@as(usize, 5), s.rowIndex(0));
    try testing.expectEqual(@as(usize, 10), s.rowIndex(1));
    try testing.expectEqual(@as(usize, 0), s.rowIndex(2));

    {
        // Test our contents rotated
        var contents = try s.testString(alloc);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n1ABCD", contents);
    }

    // Scroll by a multiple
    s.scroll(@intCast(isize, s.rows) * 4);

    // Test our row index
    try testing.expectEqual(@as(usize, 5), s.rowIndex(0));
    try testing.expectEqual(@as(usize, 10), s.rowIndex(1));
    try testing.expectEqual(@as(usize, 0), s.rowIndex(2));

    {
        // Test our contents rotated
        var contents = try s.testString(alloc);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n1ABCD", contents);
    }
}

test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5);
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(-1);

    // Test our row index
    try testing.expectEqual(@as(usize, 10), s.rowIndex(0));
    try testing.expectEqual(@as(usize, 0), s.rowIndex(1));
    try testing.expectEqual(@as(usize, 5), s.rowIndex(2));

    {
        // Test our contents rotated
        var contents = try s.testString(alloc);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n1ABCD\n2EFGH", contents);
    }

    // Scroll by a multiple
    s.scroll(-4 * @intCast(isize, s.rows));

    // Test our row index
    try testing.expectEqual(@as(usize, 10), s.rowIndex(0));
    try testing.expectEqual(@as(usize, 0), s.rowIndex(1));
    try testing.expectEqual(@as(usize, 5), s.rowIndex(2));

    {
        // Test our contents rotated
        var contents = try s.testString(alloc);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n1ABCD\n2EFGH", contents);
    }
}

test "Screen: row copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5);
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Copy
    s.scroll(1);
    s.copyRow(2, 0);

    // Test our contents
    var contents = try s.testString(alloc);
    defer alloc.free(contents);
    try testing.expectEqualStrings("2EFGH\n3IJKL\n2EFGH", contents);
}

test "Screen: resize more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resize(alloc, 10, 5);

    {
        var contents = try s.testString(alloc);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resize(alloc, 2, 5);

    {
        var contents = try s.testString(alloc);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: resize more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resize(alloc, 3, 10);

    {
        var contents = try s.testString(alloc);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resize(alloc, 3, 4);

    {
        var contents = try s.testString(alloc);
        defer alloc.free(contents);
        const expected = "1ABC\n2EFG\n3IJK";
        try testing.expectEqualStrings(expected, contents);
    }
}
