//! Screen represents the internal storage for a terminal screen, including
//! scrollback. This is implemented as a single continuous ring buffer.
//!
//! Definitions:
//!
//!   * Screen - The full screen (active + history).
//!   * Active - The area that is the current edit-able screen (the
//!       bottom of the scrollback). This is "edit-able" because it is
//!       the only part that escape sequences such as set cursor position
//!       actually affect.
//!   * History - The area that contains the lines prior to the active
//!       area. This is the scrollback area. Escape sequences can no longer
//!       affect this area.
//!   * Viewport - The area that is currently visible to the user. This
//!       can be thought of as the current window into the screen.
//!
const Screen = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const utf8proc = @import("utf8proc");
const color = @import("color.zig");
const CircBuf = @import("circ_buf.zig").CircBuf;

const log = std.log.scoped(.screen);

/// This is a single item within the storage buffer. We use a union to
/// have different types of data in a single contiguous buffer.
///
/// Note: the union is extern so that it follows the same memory layout
/// semantics as C, which allows us to have a tightly packed union.
const StorageCell = extern union {
    header: RowHeader,
    cell: Cell,

    test {
        // log.warn("header={}@{} cell={}@{} storage={}@{}", .{
        //     @sizeOf(RowHeader),
        //     @alignOf(RowHeader),
        //     @sizeOf(Cell),
        //     @alignOf(Cell),
        //     @sizeOf(StorageCell),
        //     @alignOf(StorageCell),
        // });

        // We want to be at most the size of a cell always. We have WAY
        // more cells than other fields, so we don't want to pay the cost
        // of padding due to other fields.
        try std.testing.expectEqual(@sizeOf(Cell), @sizeOf(StorageCell));
    }
};

/// The row header is at the start of every row within the storage buffer.
/// It can store row-specific data.
const RowHeader = struct {
    dirty: bool,

    /// If true, this row is soft-wrapped. The first cell of the next
    /// row is a continuous of this row.
    wrap: bool,
};

/// Cell is a single cell within the screen.
pub const Cell = struct {
    /// The primary unicode codepoint for this cell. Most cells (almost all)
    /// contain exactly one unicode codepoint. However, it is possible for
    /// cells to contain multiple if multiple codepoints are used to create
    /// a single grapheme cluster.
    ///
    /// In the case multiple codepoints make up a single grapheme, the
    /// additional codepoints can be looked up in the hash map on the
    /// Screen. Since multi-codepoints graphemes are rare, we don't want to
    /// waste memory for every cell, so we use a side lookup for it.
    char: u32 = 0,

    /// Foreground and background color. attrs.has_{bg/fg} must be checked
    /// to see if these are useful values.
    fg: color.RGB = undefined,
    bg: color.RGB = undefined,

    /// On/off attributes that can be set
    attrs: packed struct {
        has_bg: bool = false,
        has_fg: bool = false,

        bold: bool = false,
        faint: bool = false,
        underline: bool = false,
        inverse: bool = false,

        /// True if this is a wide character. This char takes up
        /// two cells. The following cell ALWAYS is a space.
        wide: bool = false,

        /// Notes that this only exists to be blank for a preceeding
        /// wide character (tail) or following (head).
        wide_spacer_tail: bool = false,
        wide_spacer_head: bool = false,
    } = .{},

    /// True if the cell should be skipped for drawing
    pub fn empty(self: Cell) bool {
        return self.char == 0;
    }

    test {
        // We use this test to ensure we always get the right size of the attrs
        // const cell: Cell = .{ .char = 0 };
        // _ = @bitCast(u8, cell.attrs);
        // try std.testing.expectEqual(1, @sizeOf(@TypeOf(cell.attrs)));
    }

    test {
        //log.warn("CELL={} {}", .{ @sizeOf(Cell), @alignOf(Cell) });
        try std.testing.expectEqual(12, @sizeOf(Cell));
    }
};

/// A row is a single row in the screen.
pub const Row = struct {
    /// Raw internal storage, do NOT write to this, use only the
    /// helpers. Writing directly to this can easily mess up state
    /// causing future crashes or misrendering.
    storage: []StorageCell,

    /// Set that this row is soft-wrapped. This doesn't change the contents
    /// of this row so the row won't be marked dirty.
    pub fn setWrapped(self: Row, v: bool) void {
        self.storage[0].header.wrap = v;
    }

    /// Clear the row, making all cells empty.
    pub fn clear(self: Row) void {
        self.fill(.{});
    }

    /// Fill the entire row with a copy of a single cell.
    pub fn fill(self: Row, cell: Cell) void {
        std.mem.set(StorageCell, self.storage[1..], .{ .cell = cell });
    }

    /// Get a pointr to the cell at column x (0-indexed). This always
    /// assumes that the cell was modified, notifying the renderer on the
    /// next call to re-render this cell. Any change detection to avoid
    /// this should be done prior.
    pub fn getCellPtr(self: Row, x: usize) *Cell {
        assert(x < self.storage.len - 1);
        return &self.storage[x + 1].cell;
    }

    /// Read-only iterator for the cells in the row.
    pub fn cellIterator(self: Row) CellIterator {
        return .{ .row = self };
    }
};

/// Used to iterate through the rows of a specific region.
pub const RowIterator = struct {
    screen: *Screen,
    tag: RowIndexTag,
    value: usize = 0,

    pub fn next(self: *RowIterator) ?Row {
        if (self.value >= self.tag.maxLen(self.screen)) return null;
        const idx = self.tag.index(self.value);
        const res = self.screen.getRow(idx);
        self.value += 1;
        return res;
    }
};

/// Used to iterate through the rows of a specific region.
pub const CellIterator = struct {
    row: Row,
    i: usize = 0,

    pub fn next(self: *CellIterator) ?Cell {
        if (self.i >= self.row.storage.len - 1) return null;
        const res = self.row.storage[self.i + 1].cell;
        self.i += 1;
        return res;
    }
};

/// RowIndex represents a row within the screen. There are various meanings
/// of a row index and this union represents the available types. For example,
/// when talking about row "0" you may want the first row in the viewport,
/// the first row in the scrollback, or the first row in the active area.
///
/// All row indexes are 0-indexed.
pub const RowIndex = union(RowIndexTag) {
    /// The index is from the top of the screen. The screen includes all
    /// the history.
    screen: usize,

    /// The index is from the top of the viewport. Therefore, depending
    /// on where the user has scrolled the viewport, "0" is different.
    viewport: usize,

    /// The index is from the top of the active area. The active area is
    /// always "rows" tall, and 0 is the top row. The active area is the
    /// "edit-able" area where the terminal cursor is.
    active: usize,

    /// The index is from the top of the history (scrollback) to just
    /// prior to the active area.
    history: usize,

    /// Convert this row index into a screen offset. This will validate
    /// the value so even if it is already a screen value, this may error.
    pub fn toScreen(self: RowIndex, screen: *const Screen) RowIndex {
        const y = switch (self) {
            .screen => |y| y: {
                assert(y < RowIndexTag.screen.maxLen(screen));
                break :y y;
            },

            .viewport => |y| y: {
                assert(y < RowIndexTag.viewport.maxLen(screen));
                break :y y + screen.viewport;
            },

            .active => |y| y: {
                assert(y < RowIndexTag.active.maxLen(screen));
                break :y RowIndexTag.history.maxLen(screen) + y;
            },

            .history => |y| y: {
                assert(y < RowIndexTag.history.maxLen(screen));
                break :y y;
            },
        };

        return .{ .screen = y };
    }
};

/// The tags of RowIndex
pub const RowIndexTag = enum {
    screen,
    viewport,
    active,
    history,

    /// The max length for a given tag. This is a length, not an index,
    /// so it is 1-indexed. If the value is zero, it means that this
    /// section of the screen is empty or disabled.
    pub fn maxLen(self: RowIndexTag, screen: *const Screen) usize {
        const rows_written = screen.rowsWritten();

        return switch (self) {
            // Screen can be any of the written rows
            .screen => rows_written,

            // Viewport can be any of the written rows or the max size
            // of a viewport.
            .viewport => @minimum(screen.rows, rows_written),

            // History is all the way up to the top of our active area. If
            // we haven't filled our active area, there is no history.
            .history => if (rows_written > screen.rows) rows_written - screen.rows else 0,

            // Active area can be any number of rows. We ignore rows
            // written here because this is the only row index that can
            // actively grow our rows.
            .active => screen.rows,
        };
    }

    /// Construct a RowIndex from a tag.
    pub fn index(self: RowIndexTag, value: usize) RowIndex {
        return switch (self) {
            .screen => .{ .screen = value },
            .viewport => .{ .viewport = value },
            .active => .{ .active = value },
            .history => .{ .history = value },
        };
    }
};

const StorageBuf = CircBuf(StorageCell);

/// The allocator used for all the storage operations
alloc: Allocator,

/// The full set of storage.
storage: StorageBuf,

/// The number of rows and columns in the visible space.
rows: usize,
cols: usize,

/// The maximum number of lines that are available in scrollback. This
/// is in addition to the number of visible rows.
max_scrollback: usize,

/// The row (offset from the top) where the viewport currently is.
viewport: usize,

/// Initialize a new screen.
pub fn init(
    alloc: Allocator,
    rows: usize,
    cols: usize,
    max_scrollback: usize,
) !Screen {
    // * Our buffer size is preallocated to fit double our visible space
    //   or the maximum scrollback whichever is smaller.
    // * We add +1 to cols to fit the row header
    const buf_size = (rows + max_scrollback) * (cols + 1);
    //const buf_size = (rows + @minimum(max_scrollback, rows)) * (cols + 1);

    return Screen{
        .alloc = alloc,
        .storage = try StorageBuf.init(alloc, buf_size),
        .rows = rows,
        .cols = cols,
        .max_scrollback = max_scrollback,
        .viewport = 0,
    };
}

pub fn deinit(self: *Screen) void {
    self.storage.deinit(self.alloc);
}

/// Returns true if the viewport is scrolled to the bottom of the screen.
pub fn viewportIsBottom(self: Screen) bool {
    return self.viewport >= RowIndexTag.history.maxLen(&self);
}

/// Returns an iterator that can be used to iterate over all of the rows
/// from index zero of the given row index type. This can therefore iterate
/// from row 0 of the active area, history, viewport, etc.
pub fn rowIterator(self: *Screen, tag: RowIndexTag) RowIterator {
    return .{ .screen = self, .tag = tag };
}

/// Returns the row at the given index. This row is writable, although
/// only the active area should probably be written to.
pub fn getRow(self: *Screen, index: RowIndex) Row {
    // Get our offset into storage
    const offset = index.toScreen(self).screen * (self.cols + 1);

    // Get the slices into the storage. This should never wrap because
    // we're perfectly aligned on row boundaries.
    const slices = self.storage.getPtrSlice(offset, self.cols + 1);
    assert(slices[0].len == self.cols + 1 and slices[1].len == 0);

    return .{ .storage = slices[0] };
}

/// Returns the offset into the storage buffer that the given row can
/// be found. This assumes valid input and will crash if the input is
/// invalid.
fn rowOffset(self: Screen, index: RowIndex) usize {
    // +1 for row header
    return index.toScreen(&self).screen * (self.cols + 1);
}

/// Returns the number of rows that have actually been written to the
/// screen. This assumes a row is "written" if getRow was ever called
/// on the row.
fn rowsWritten(self: Screen) usize {
    // The number of rows we've actually written into our buffer
    // This should always be cleanly divisible since we only request
    // data in row chunks from the buffer.
    assert(@mod(self.storage.len(), self.cols + 1) == 0);
    return self.storage.len() / (self.cols + 1);
}

/// The number of rows our backing storage supports. This should
/// always be self.rows but we use the backing storage as a source of truth.
fn rowsCapacity(self: Screen) usize {
    assert(@mod(self.storage.capacity(), self.cols + 1) == 0);
    return self.storage.capacity() / (self.cols + 1);
}

/// Scroll behaviors for the scroll function.
pub const Scroll = union(enum) {
    /// Scroll to the top of the scroll buffer. The first line of the
    /// viewport will be the top line of the scroll buffer.
    top: void,

    /// Scroll to the bottom, where the last line of the viewport
    /// will be the last line of the buffer. TODO: are we sure?
    bottom: void,

    /// Scroll up (negative) or down (positive) some fixed amount.
    /// Scrolling direction (up/down) describes the direction the viewport
    /// moves, not the direction text moves. This is the colloquial way that
    /// scrolling is described: "scroll the page down".
    delta: isize,

    /// Same as delta but scrolling down will not grow the scrollback.
    /// Scrolling down at the bottom will do nothing (similar to how
    /// delta at the top does nothing).
    delta_no_grow: isize,
};

/// Scroll the screen by the given behavior. Note that this will always
/// "move" the screen. It is up to the caller to determine if they actually
/// want to do that yet (i.e. are they writing to the end of the screen
/// or not).
pub fn scroll(self: *Screen, behavior: Scroll) void {
    switch (behavior) {
        // Setting viewport offset to zero makes row 0 be at self.top
        // which is the top!
        .top => self.viewport = 0,

        // Bottom is the end of the history area (end of history is the
        // top of the active area).
        .bottom => self.viewport = RowIndexTag.history.maxLen(self),

        // TODO: deltas greater than the entire scrollback
        .delta => |delta| self.scrollDelta(delta, true),
        .delta_no_grow => |delta| self.scrollDelta(delta, false),
    }
}

fn scrollDelta(self: *Screen, delta: isize, grow: bool) void {
    // If we're scrolling up, then we just subtract and we're done.
    // We just clamp at 0 which blocks us from scrolling off the top.
    if (delta < 0) {
        self.viewport -|= @intCast(usize, -delta);
        return;
    }

    // If we're scrolling down and not growing, then we just
    // add to the viewport and clamp at the bottom.
    const viewport_max = RowIndexTag.history.maxLen(self);
    if (!grow) {
        self.viewport = @minimum(
            viewport_max,
            self.viewport +| @intCast(usize, delta),
        );
        return;
    }

    // {
    //     const rows_capacity = self.rowsCapacity();
    //     const rows_written = self.rowsWritten();
    //     log.warn("rows_written={} rows_capacity={} vp={} vp_new={}", .{
    //         rows_written,
    //         rows_capacity,
    //         self.viewport,
    //         self.viewport + @intCast(usize, delta),
    //     });
    // }

    // Add our delta to our viewport. If we're less than the max currently
    // allowed to scroll to the bottom (the end of the history), then we
    // have space and we just return.
    self.viewport +|= @intCast(usize, delta);
    if (self.viewport <= viewport_max) return;

    // Our viewport is bigger than our max. The number of new rows we need
    // in our buffer is our value minus the max.
    const new_rows_needed = self.viewport - viewport_max;

    // If we can fit this into our existing capacity, then just grow to it.
    const rows_capacity = self.rowsCapacity();
    const rows_written = self.rowsWritten();
    if (rows_written + new_rows_needed <= rows_capacity) {
        // Ensure we have "written" this data into the circular buffer.
        _ = self.storage.getPtrSlice(
            self.viewport * (self.cols + 1),
            self.cols + 1,
        );
        return;
    }

    // We can't fit our new rows into the capacity, so the amount
    // between what we need and the capacity needs to be deleted. We
    // scroll "up" by that much to offset this.
    const rows_to_delete = (rows_written + new_rows_needed) - rows_capacity;
    self.viewport -= rows_to_delete;
    self.storage.deleteOldest(rows_to_delete * (self.cols + 1));

    // If we grew down like this, we must be at the bottom.
    assert(self.viewportIsBottom());
}

/// Writes a basic string into the screen for testing. Newlines (\n) separate
/// each row. If a line is longer than the available columns, soft-wrapping
/// will occur. This will automatically handle basic wide chars.
pub fn testWriteString(self: *Screen, text: []const u8) void {
    var y: usize = 0;
    var x: usize = 0;

    const view = std.unicode.Utf8View.init(text) catch unreachable;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        // Explicit newline forces a new row
        if (c == '\n') {
            y += 1;
            x = 0;
            continue;
        }

        // If we're writing past the end of the active area, scroll.
        if (y >= self.rows) {
            y -= 1;
            self.scroll(.{ .delta = 1 });
        }

        // Get our row
        var row = self.getRow(.{ .active = y });

        // If we're writing past the end, we need to soft wrap.
        if (x == self.cols) {
            row.setWrapped(true);
            y += 1;
            x = 0;
            if (y >= self.rows) {
                y -= 1;
                self.scroll(.{ .delta = 1 });
            }
            row = self.getRow(.{ .active = y });
        }

        // If our character is double-width, handle it.
        const width = utf8proc.charwidth(c);
        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                const cell = row.getCellPtr(x);
                cell.char = @intCast(u32, c);
            },

            2 => {
                if (x == self.cols - 1) {
                    const cell = row.getCellPtr(x);
                    cell.char = ' ';
                    cell.attrs.wide_spacer_head = true;

                    // wrap
                    row.setWrapped(true);
                    y += 1;
                    x = 0;
                    if (y >= self.rows) {
                        y -= 1;
                        self.scroll(.{ .delta = 1 });
                    }
                    row = self.getRow(.{ .active = y });
                }

                {
                    const cell = row.getCellPtr(x);
                    cell.char = @intCast(u32, c);
                    cell.attrs.wide = true;
                }

                {
                    x += 1;
                    const cell = row.getCellPtr(x);
                    cell.char = ' ';
                    cell.attrs.wide_spacer_tail = true;
                }
            },

            else => unreachable,
        }

        x += 1;
    }
}

/// Turns the screen into a string. Different regions of the screen can
/// be selected using the "tag", i.e. if you want to output the viewport,
/// the scrollback, the full screen, etc.
///
/// This is only useful for testing.
pub fn testString(self: *Screen, alloc: Allocator, tag: RowIndexTag) ![]const u8 {
    const buf = try alloc.alloc(u8, self.storage.len() * 4);

    var i: usize = 0;
    var y: usize = 0;
    var rows = self.rowIterator(tag);
    while (rows.next()) |row| {
        defer y += 1;

        if (y > 0) {
            buf[i] = '\n';
            i += 1;
        }

        var cells = row.cellIterator();
        while (cells.next()) |cell| {
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

test "Screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    try testing.expect(s.rowsWritten() == 0);

    // Sanity check that our test helpers work
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try testing.expect(s.rowsWritten() == 3);
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Test the row iterator
    var count: usize = 0;
    var iter = s.rowIterator(.viewport);
    while (iter.next()) |row| {
        // Rows should be pointer equivalent to getRow
        const row_other = s.getRow(.{ .viewport = count });
        try testing.expectEqual(row.storage.ptr, row_other.storage.ptr);
        count += 1;
    }

    // Should go through all rows
    try testing.expectEqual(@as(usize, 3), count);

    // Should be able to easily clear screen
    {
        var it = s.rowIterator(.viewport);
        while (it.next()) |row| row.fill(.{ .char = 'A' });
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("AAAAA\nAAAAA\nAAAAA", contents);
    }
}

test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll down, should still be bottom
    s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());

    // Test our row index
    try testing.expectEqual(@as(usize, 0), s.rowOffset(.{ .active = 0 }));
    try testing.expectEqual(@as(usize, 6), s.rowOffset(.{ .active = 1 }));
    try testing.expectEqual(@as(usize, 12), s.rowOffset(.{ .active = 2 }));

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom does nothing
    s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scrolling up does nothing, but allows it
    s.scroll(.{ .delta = -1 });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 1);
    defer s.deinit();
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta = 1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .bottom = {} });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling back should make it visible again
    s.scroll(.{ .delta = -1 });
    try testing.expect(!s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling back again should do nothing
    s.scroll(.{ .delta = -1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling forward with no grow should do nothing
    s.scroll(.{ .delta_no_grow = 1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the top should work
    s.scroll(.{ .top = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Should be able to easily clear active area only
    var it = s.rowIterator(.active);
    while (it.next()) |row| row.clear();
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: scrollback empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 50);
    defer s.deinit();
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_no_grow = 1 });

    {
        // Test our contents
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: history region with no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 0);
    defer s.deinit();

    // Write a bunch that WOULD invoke scrollback if exists
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Verify no scrollback
    var it = s.rowIterator(.history);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try testing.expect(count == 0);
}

test "Screen: history region with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 2);
    defer s.deinit();

    // Write a bunch that WOULD invoke scrollback if exists
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        // Test our contents
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    {
        var contents = try s.testString(alloc, .history);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
