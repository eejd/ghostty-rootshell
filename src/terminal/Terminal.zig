//! The primary terminal emulation structure. This represents a single
//!
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ansi = @import("ansi.zig");
const csi = @import("csi.zig");
const sgr = @import("sgr.zig");
const Tabstops = @import("Tabstops.zig");
const trace = @import("../tracy/tracy.zig").trace;
const color = @import("color.zig");
const Screen = @import("Screen.zig");

const log = std.log.scoped(.terminal);

/// Default tabstop interval
const TABSTOP_INTERVAL = 8;

/// Screen is the current screen state.
screen: Screen,

/// Cursor position.
cursor: Cursor,

/// Saved cursor saved with DECSC (ESC 7).
saved_cursor: Cursor,

/// Where the tabstops are.
tabstops: Tabstops,

/// The size of the terminal.
rows: usize,
cols: usize,

/// The current scrolling region.
scrolling_region: ScrollingRegion,

/// Modes
// TODO: turn into a bitset probably
mode_origin: bool = false,
mode_reverse_colors: bool = false,

/// Scrolling region is the area of the screen designated where scrolling
/// occurs. Wen scrolling the screen, only this viewport is scrolled.
const ScrollingRegion = struct {
    // Precondition: top < bottom
    top: usize,
    bottom: usize,
};

/// Cursor represents the cursor state.
const Cursor = struct {
    // x, y where the cursor currently exists (0-indexed).
    x: usize = 0,
    y: usize = 0,

    // pen is the current cell styling to apply to new cells.
    pen: Screen.Cell = .{ .char = 0 },
};

/// Initialize a new terminal.
pub fn init(alloc: Allocator, cols: usize, rows: usize) !Terminal {
    return Terminal{
        .cols = cols,
        .rows = rows,
        .screen = try Screen.init(alloc, rows, cols),
        .cursor = .{},
        .saved_cursor = .{},
        .tabstops = try Tabstops.init(alloc, cols, TABSTOP_INTERVAL),
        .scrolling_region = .{
            .top = 0,
            .bottom = rows - 1,
        },
    };
}

pub fn deinit(self: *Terminal, alloc: Allocator) void {
    self.tabstops.deinit(alloc);
    self.screen.deinit(alloc);
    self.* = undefined;
}

/// Resize the underlying terminal.
pub fn resize(self: *Terminal, alloc: Allocator, cols: usize, rows: usize) !void {
    // TODO: test, wrapping, etc.

    // Resize our tabstops
    // TODO: use resize, but it doesn't set new tabstops
    if (self.cols != cols) {
        self.tabstops.deinit(alloc);
        self.tabstops = try Tabstops.init(alloc, cols, 8);
    }

    // If we're making the screen smaller, dealloc the unused items.
    // TODO: reflow
    try self.screen.resize(alloc, rows, cols);

    // Set our size
    self.cols = cols;
    self.rows = rows;

    // Reset the scrolling region
    self.scrolling_region = .{
        .top = 0,
        .bottom = rows - 1,
    };

    // Move our cursor
    self.cursor.x = @minimum(self.cursor.x, self.cols - 1);
    self.cursor.y = @minimum(self.cursor.y, self.rows - 1);
}

/// Return the current string value of the terminal. Newlines are
/// encoded as "\n". This omits any formatting such as fg/bg.
///
/// The caller must free the string.
pub fn plainString(self: Terminal, alloc: Allocator) ![]const u8 {
    return try self.screen.testString(alloc);
}

/// Save cursor position and further state.
///
/// The primary and alternate screen have distinct save state. One saved state
/// is kept per screen (main / alternative). If for the current screen state
/// was already saved it is overwritten.
pub fn saveCursor(self: *Terminal) void {
    self.saved_cursor = self.cursor;
}

/// Restore cursor position and other state.
///
/// The primary and alternate screen have distinct save state.
/// If no save was done before values are reset to their initial values.
pub fn restoreCursor(self: *Terminal) void {
    self.cursor = self.saved_cursor;
}

/// TODO: test
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void {
    switch (attr) {
        .unset => {
            self.cursor.pen.fg = null;
            self.cursor.pen.bg = null;
            self.cursor.pen.attrs = .{};
        },

        .bold => {
            self.cursor.pen.attrs.bold = 1;
        },

        .underline => {
            self.cursor.pen.attrs.underline = 1;
        },

        .inverse => {
            self.cursor.pen.attrs.inverse = 1;
        },

        .direct_color_fg => |rgb| {
            self.cursor.pen.fg = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            };
        },

        .direct_color_bg => |rgb| {
            self.cursor.pen.bg = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            };
        },

        .@"8_fg" => |n| self.cursor.pen.fg = color.default[@enumToInt(n)],

        .@"8_bg" => |n| self.cursor.pen.bg = color.default[@enumToInt(n)],

        .@"8_bright_fg" => |n| self.cursor.pen.fg = color.default[@enumToInt(n)],

        .@"8_bright_bg" => |n| self.cursor.pen.bg = color.default[@enumToInt(n)],

        .@"256_fg" => |idx| self.cursor.pen.fg = color.default[idx],

        .@"256_bg" => |idx| self.cursor.pen.bg = color.default[idx],

        else => return error.InvalidAttribute,
    }
}

pub fn print(self: *Terminal, c: u21) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Build our cell
    const cell = self.screen.getCell(self.cursor.y, self.cursor.x);
    cell.* = self.cursor.pen;
    cell.char = @intCast(u32, c);

    // Move the cursor
    self.cursor.x += 1;

    // TODO: wrap
    if (self.cursor.x == self.cols) {
        self.cursor.x -= 1;
    }
}

/// Resets all margins and fills the whole screen with the character 'E'
///
/// Sets the cursor to the top left corner.
pub fn decaln(self: *Terminal) void {
    // Reset margins, also sets cursor to top-left
    self.setScrollingRegion(0, 0);

    // Fill with Es, does not move cursor. We reset fg/bg so we can just
    // optimize here by doing row copies.
    const filled = self.screen.getRow(0);
    var col: usize = 0;
    while (col < self.cols) : (col += 1) {
        filled[col] = .{ .char = 'E' };
    }

    var row: usize = 1;
    while (row < self.rows) : (row += 1) {
        std.mem.copy(Screen.Cell, self.screen.getRow(row), filled);
    }
}

/// Move the cursor to the next line in the scrolling region, possibly scrolling.
///
/// If the cursor is outside of the scrolling region: move the cursor one line
/// down if it is not on the bottom-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///   If the cursor is on the bottom-most line of the scrolling region:
///     invoke scroll up with amount=1
///   If the cursor is not on the bottom-most line of the scrolling region:
///     move the cursor one line down
///
/// This unsets the pending wrap state without wrapping.
pub fn index(self: *Terminal) void {
    // If we're at the end of the screen, scroll up. This is surprisingly
    // common because most terminals live with a full screen so we do this
    // check first.
    if (self.cursor.y == self.rows - 1) {
        // Outside of the scroll region we do nothing.
        if (self.cursor.y < self.scrolling_region.top or
            self.cursor.y > self.scrolling_region.bottom) return;

        self.scrollUp();
        return;
    }

    // Increase cursor by 1
    self.cursor.y += 1;
}

/// Move the cursor to the previous line in the scrolling region, possibly
/// scrolling.
///
/// If the cursor is outside of the scrolling region, move the cursor one
/// line up if it is not on the top-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///
///   * If the cursor is on the top-most line of the scrolling region:
///     invoke scroll down with amount=1
///   * If the cursor is not on the top-most line of the scrolling region:
///     move the cursor one line up
pub fn reverseIndex(self: *Terminal) !void {
    // TODO: scrolling region

    if (self.cursor.y == 0) {
        try self.scrollDown();
    } else {
        self.cursor.y -|= 1;
    }
}

// Set Cursor Position. Move cursor to the position indicated
// by row and column (1-indexed). If column is 0, it is adjusted to 1.
// If column is greater than the right-most column it is adjusted to
// the right-most column. If row is 0, it is adjusted to 1. If row is
// greater than the bottom-most row it is adjusted to the bottom-most
// row.
pub fn setCursorPos(self: *Terminal, row: usize, col: usize) void {
    // If cursor origin mode is set the cursor row will be moved relative to
    // the top margin row and adjusted to be above or at bottom-most row in
    // the current scroll region.
    //
    // If origin mode is set and left and right margin mode is set the cursor
    // will be moved relative to the left margin column and adjusted to be on
    // or left of the right margin column.
    const params: struct {
        x_offset: usize = 0,
        y_offset: usize = 0,
        x_max: usize,
        y_max: usize,
    } = if (self.mode_origin) .{
        .x_offset = 0, // TODO: left/right margins
        .x_max = self.cols, // TODO: left/right margins
        .y_offset = self.scrolling_region.top + 1,
        .y_max = self.scrolling_region.bottom + 1, // We need this 1-indexed
    } else .{
        .x_max = self.cols,
        .y_max = self.rows,
    };

    self.cursor.x = @minimum(params.x_max, col) -| 1;
    self.cursor.y = @minimum(params.y_max, row + params.y_offset) -| 1;
}

/// Erase the display.
/// TODO: test
pub fn eraseDisplay(
    self: *Terminal,
    alloc: Allocator,
    mode: csi.EraseDisplay,
) !void {
    switch (mode) {
        .complete => {
            const all = self.screen.getVisible();
            std.mem.set(Screen.Cell, all, self.cursor.pen);
        },

        .below => {
            // All lines to the right (including the cursor)
            var x: usize = self.cursor.x;
            while (x < self.cols) : (x += 1) {
                const cell = try self.getOrPutCell(alloc, x, self.cursor.y);
                cell.* = self.cursor.pen;
                cell.char = 0;
            }

            // All lines below
            var y: usize = self.cursor.y + 1;
            while (y < self.rows) : (y += 1) {
                x = 0;
                while (x < self.cols) : (x += 1) {
                    const cell = try self.getOrPutCell(alloc, x, y);
                    cell.* = self.cursor.pen;
                    cell.char = 0;
                }
            }
        },

        .above => {
            // Erase to the left (including the cursor)
            var x: usize = 0;
            while (x <= self.cursor.x) : (x += 1) {
                const cell = try self.getOrPutCell(alloc, x, self.cursor.y);
                cell.* = self.cursor.pen;
                cell.char = 0;
            }

            // All lines above
            var y: usize = 0;
            while (y < self.cursor.y) : (y += 1) {
                x = 0;
                while (x < self.cols) : (x += 1) {
                    const cell = try self.getOrPutCell(alloc, x, y);
                    cell.* = self.cursor.pen;
                    cell.char = 0;
                }
            }
        },

        else => {
            log.err("unimplemented display mode: {}", .{mode});
            @panic("unimplemented");
        },
    }
}

/// Erase the line.
/// TODO: test
pub fn eraseLine(
    self: *Terminal,
    mode: csi.EraseLine,
) !void {
    switch (mode) {
        .right => {
            const row = self.screen.getRow(self.cursor.y);
            std.mem.set(Screen.Cell, row[self.cursor.x..], self.cursor.pen);
        },

        .left => {
            const row = self.screen.getRow(self.cursor.y);
            std.mem.set(Screen.Cell, row[0..self.cursor.x], self.cursor.pen);
        },

        .complete => {
            const row = self.screen.getRow(self.cursor.y);
            std.mem.set(Screen.Cell, row, self.cursor.pen);
        },

        else => {
            log.err("unimplemented erase line mode: {}", .{mode});
            @panic("unimplemented");
        },
    }
}

/// Removes amount characters from the current cursor position to the right.
/// The remaining characters are shifted to the left and space from the right
/// margin is filled with spaces.
///
/// If amount is greater than the remaining number of characters in the
/// scrolling region, it is adjusted down.
///
/// Does not change the cursor position.
///
/// TODO: test
pub fn deleteChars(self: *Terminal, count: usize) !void {
    const line = self.screen.getRow(self.cursor.y);

    // Our last index is at most the end of the number of chars we have
    // in the current line.
    const end = self.cols - count;

    // Shift
    var i: usize = self.cursor.x;
    while (i < end) : (i += 1) {
        const j = i + count;
        line[i] = line[j];
        line[j].char = 0;
    }
}

// TODO: test, docs
pub fn eraseChars(self: *Terminal, alloc: Allocator, count: usize) !void {
    // Our last index is at most the end of the number of chars we have
    // in the current line.
    const end = @minimum(self.cols, self.cursor.x + count);

    // Shift
    var x: usize = self.cursor.x;
    while (x < end) : (x += 1) {
        const cell = try self.getOrPutCell(alloc, x, self.cursor.y);
        cell.* = self.cursor.pen;
        cell.char = 0;
    }
}

/// Move the cursor to the left amount cells. If amount is 0, adjust it to 1.
/// TODO: test
pub fn cursorLeft(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: scroll region, wrap

    self.cursor.x -|= if (count == 0) 1 else count;
}

/// Move the cursor right amount columns. If amount is greater than the
/// maximum move distance then it is internally adjusted to the maximum.
/// This sequence will not scroll the screen or scroll region. If amount is
/// 0, adjust it to 1.
/// TODO: test
pub fn cursorRight(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.cursor.x += count;
    if (self.cursor.x >= self.cols) {
        self.cursor.x = self.cols - 1;
    }
}

/// Move the cursor down amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. This sequence
/// will not scroll the screen or scroll region. If amount is 0, adjust it to 1.
// TODO: test
pub fn cursorDown(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.cursor.y += count;
    if (self.cursor.y >= self.rows) {
        self.cursor.y = self.rows - 1;
    }
}

/// Move the cursor up amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. If amount is
/// 0, adjust it to 1.
// TODO: test
pub fn cursorUp(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.cursor.y -|= count;
}

/// Backspace moves the cursor back a column (but not less than 0).
pub fn backspace(self: *Terminal) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.cursor.x -|= 1;
}

/// Horizontal tab moves the cursor to the next tabstop, clearing
/// the screen to the left the tabstop.
pub fn horizontalTab(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    while (self.cursor.x < self.cols) {
        // Clear
        try self.print(' ');

        // If the last cursor position was a tabstop we return. We do
        // "last cursor position" because we want a space to be written
        // at the tabstop unless we're at the end (the while condition).
        if (self.tabstops.get(self.cursor.x)) return;
    }
}

/// Clear tab stops.
/// TODO: test
pub fn tabClear(self: *Terminal, cmd: csi.TabClear) void {
    switch (cmd) {
        .current => self.tabstops.unset(self.cursor.x),
        .all => self.tabstops.reset(0),
        else => log.warn("invalid or unknown tab clear setting: {}", .{cmd}),
    }
}

/// Set a tab stop on the current cursor.
/// TODO: test
pub fn tabSet(self: *Terminal) void {
    self.tabstops.set(self.cursor.x);
}

/// Carriage return moves the cursor to the first column.
pub fn carriageReturn(self: *Terminal) void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: left/right margin mode
    // TODO: origin mode
    // TODO: wrap state

    self.cursor.x = 0;
}

/// Linefeed moves the cursor to the next line.
pub fn linefeed(self: *Terminal) void {
    self.index();
}

/// Insert amount lines at the current cursor row. The contents of the line
/// at the current cursor row and below (to the bottom-most line in the
/// scrolling region) are shifted down by amount lines. The contents of the
/// amount bottom-most lines in the scroll region are lost.
///
/// This unsets the pending wrap state without wrapping. If the current cursor
/// position is outside of the current scroll region it does nothing.
///
/// If amount is greater than the remaining number of lines in the scrolling
/// region it is adjusted down (still allowing for scrolling out every remaining
/// line in the scrolling region)
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// All cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn insertLines(self: *Terminal, alloc: Allocator, count: usize) !void {
    // Move the cursor to the left margin
    self.cursor.x = 0;

    // Remaining rows from our cursor
    const rem = self.scrolling_region.bottom - self.cursor.y + 1;

    // If count is greater than the amount of rows, adjust down.
    const adjusted_count = @minimum(count, rem);

    // The the top `scroll_amount` lines need to move to the bottom
    // scroll area. We may have nothing to scroll if we're clearing.
    const scroll_amount = rem - adjusted_count;
    var y: usize = self.scrolling_region.bottom;
    const top = y - scroll_amount;

    // Ensure we have the lines populated to the end
    while (y > top) : (y -= 1) {
        self.screen.copyRow(y, y - adjusted_count);
    }

    // Insert count blank lines
    y = self.cursor.y;
    while (y < self.cursor.y + adjusted_count) : (y += 1) {
        var x: usize = 0;
        while (x < self.cols) : (x += 1) {
            const cell = try self.getOrPutCell(alloc, x, y);
            cell.* = self.cursor.pen;
            cell.char = 0;
        }
    }
}

/// Removes amount lines from the current cursor row down. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up is
/// filled with empty lines.
///
/// If the current cursor position is outside of the current scroll region it
/// does nothing. If amount is greater than the remaining number of lines in the
/// scrolling region it is adjusted down.
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// If the cell movement splits a multi cell character that character cleared,
/// by replacing it by spaces, keeping its current attributes. All other
/// cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn deleteLines(self: *Terminal, count: usize) void {
    // TODO: scroll region bounds

    // Move the cursor to the left margin
    self.cursor.x = 0;

    // Remaining number of lines in the scrolling region
    const rem = self.scrolling_region.bottom - self.cursor.y + 1;

    // If the count is more than our remaining lines, we adjust down.
    const adjusted_count = @minimum(count, rem);

    // Scroll up the count amount.
    var y: usize = self.cursor.y;
    while (y <= self.scrolling_region.bottom - adjusted_count) : (y += 1) {
        self.screen.copyRow(y, y + adjusted_count);
    }

    while (y <= self.scrolling_region.bottom) : (y += 1) {
        const row = self.screen.getRow(y);
        std.mem.set(Screen.Cell, row, self.cursor.pen);
    }
}

/// Scroll the text up by one row.
pub fn scrollUp(self: *Terminal) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.screen.scroll(1);
    const last = self.screen.getRow(self.rows - 1);
    for (last) |*cell| cell.char = 0;
}

/// Scroll the text down by one row.
/// TODO: test
pub fn scrollDown(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    self.screen.scroll(-1);
    const top = self.screen.getRow(0);
    for (top) |*cell| cell.char = 0;
}

/// Set Top and Bottom Margins If bottom is not specified, 0 or bigger than
/// the number of the bottom-most row, it is adjusted to the number of the
/// bottom most row.
///
/// If top < bottom set the top and bottom row of the scroll region according
/// to top and bottom and move the cursor to the top-left cell of the display
/// (when in cursor origin mode is set to the top-left cell of the scroll region).
///
/// Otherwise: Set the top and bottom row of the scroll region to the top-most
/// and bottom-most line of the screen.
///
/// Top and bottom are 1-indexed.
pub fn setScrollingRegion(self: *Terminal, top: usize, bottom: usize) void {
    var t = if (top == 0) 1 else top;
    var b = @minimum(bottom, self.rows);
    if (t >= b) {
        t = 1;
        b = self.rows;
    }

    self.scrolling_region = .{
        .top = t - 1,
        .bottom = b - 1,
    };

    self.setCursorPos(1, 1);
}

fn getOrPutCell(self: *Terminal, alloc: Allocator, x: usize, y: usize) !*Screen.Cell {
    const tracy = trace(@src());
    defer tracy.end();

    _ = alloc;
    return self.screen.getCell(y, x);
}

test "Terminal: input with no control characters" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.cursor.x);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

test "Terminal: linefeed and carriage return" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    t.carriageReturn();
    t.linefeed();
    for ("world") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.cursor.x);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nworld", str);
    }
}

test "Terminal: backspace" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // BS
    for ("hello") |c| try t.print(c);
    t.backspace();
    try t.print('y');
    try testing.expectEqual(@as(usize, 0), t.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.cursor.x);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("helly", str);
    }
}

test "Terminal: horizontal tabs" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 5);
    defer t.deinit(alloc);

    // HT
    try t.print('1');
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 7), t.cursor.x);

    // HT
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 15), t.cursor.x);
}

test "Terminal: setCursorPosition" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), t.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.cursor.y);

    // Setting it to 0 should keep it zero (1 based)
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.cursor.y);

    // Should clamp to size
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.cursor.y);

    // Origin mode
    t.mode_origin = true;

    // No change without a scroll region
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.cursor.y);

    // Set the scroll region
    t.setScrollingRegion(10, t.rows);
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.cursor.y);

    t.setCursorPos(100, 0);
    try testing.expectEqual(@as(usize, 0), t.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.cursor.y);

    t.setScrollingRegion(10, 11);
    t.setCursorPos(2, 0);
    try testing.expectEqual(@as(usize, 0), t.cursor.x);
    try testing.expectEqual(@as(usize, 10), t.cursor.y);
}

test "Terminal: setScrollingRegion" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Initial value
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);

    // Move our cusor so we can verify we move it back
    t.setCursorPos(5, 5);
    t.setScrollingRegion(3, 7);

    // Cursor should move back to top-left
    try testing.expectEqual(@as(usize, 0), t.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.cursor.y);

    // Scroll region is set
    try testing.expectEqual(@as(usize, 2), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 6), t.scrolling_region.bottom);

    // Scroll region invalid
    t.setScrollingRegion(7, 3);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);

    // Scroll region with zero top and bottom
    t.setScrollingRegion(0, 0);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);
}

test "Terminal: deleteLines" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 80);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    t.linefeed();
    try t.print('B');
    t.carriageReturn();
    t.linefeed();
    try t.print('C');
    t.carriageReturn();
    t.linefeed();
    try t.print('D');

    t.cursorUp(2);
    t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    t.linefeed();

    // We should be
    try testing.expectEqual(@as(usize, 0), t.cursor.x);
    try testing.expectEqual(@as(usize, 2), t.cursor.y);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nE\nD", str);
    }
}

test "Terminal: deleteLines with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 80);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    t.linefeed();
    try t.print('B');
    t.carriageReturn();
    t.linefeed();
    try t.print('C');
    t.carriageReturn();
    t.linefeed();
    try t.print('D');

    t.setScrollingRegion(1, 3);
    t.setCursorPos(1, 1);
    t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.cursor.y);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nC\n\nD", str);
    }
}

test "Terminal: insertLines" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    t.linefeed();
    try t.print('B');
    t.carriageReturn();
    t.linefeed();
    try t.print('C');
    t.carriageReturn();
    t.linefeed();
    try t.print('D');
    t.carriageReturn();
    t.linefeed();
    try t.print('E');

    // Move to row 2
    t.setCursorPos(2, 1);

    // Insert two lines
    try t.insertLines(alloc, 2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\nB\nC", str);
    }
}

test "Terminal: insertLines with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 6);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    t.linefeed();
    try t.print('B');
    t.carriageReturn();
    t.linefeed();
    try t.print('C');
    t.carriageReturn();
    t.linefeed();
    try t.print('D');
    t.carriageReturn();
    t.linefeed();
    try t.print('E');

    t.setScrollingRegion(1, 2);
    t.setCursorPos(1, 1);
    try t.insertLines(alloc, 1);

    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nC\nD\nE", str);
    }
}

test "Terminal: insertLines more than remaining" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    t.linefeed();
    try t.print('B');
    t.carriageReturn();
    t.linefeed();
    try t.print('C');
    t.carriageReturn();
    t.linefeed();
    try t.print('D');
    t.carriageReturn();
    t.linefeed();
    try t.print('E');

    // Move to row 2
    t.setCursorPos(2, 1);

    // Insert a bunch of  lines
    try t.insertLines(alloc, 20);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: reverseIndex" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    t.linefeed();
    try t.print('B');
    t.carriageReturn();
    t.linefeed();
    try t.print('C');
    try t.reverseIndex();
    try t.print('D');
    t.carriageReturn();
    t.linefeed();
    t.carriageReturn();
    t.linefeed();

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nBD\nC", str);
    }
}

test "Terminal: reverseIndex from the top" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    t.linefeed();
    try t.print('B');
    t.carriageReturn();
    t.linefeed();
    t.carriageReturn();
    t.linefeed();

    t.setCursorPos(1, 1);
    try t.reverseIndex();
    try t.print('D');

    t.carriageReturn();
    t.linefeed();
    t.setCursorPos(1, 1);
    try t.reverseIndex();
    try t.print('E');
    t.carriageReturn();
    t.linefeed();

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nD\nA\nB", str);
    }
}

test "Terminal: index" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.index();
    try t.print('A');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

test "Terminal: index from the bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    t.index();

    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }
}

test "Terminal: index outside of scrolling region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), t.cursor.y);
    t.setScrollingRegion(2, 5);
    t.index();
    try testing.expectEqual(@as(usize, 1), t.cursor.y);
}

test "Terminal: index from the bottom outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 2);
    t.setCursorPos(5, 1);
    try t.print('A');
    t.index();
    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\nAB", str);
    }
}

test "Terminal: DECALN" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 2);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    t.linefeed();
    try t.print('B');
    t.decaln();

    try testing.expectEqual(@as(usize, 0), t.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.cursor.x);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EE\nEE", str);
    }
}
