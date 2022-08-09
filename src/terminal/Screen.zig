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

// FUTURE: Today this is implemented as a single contiguous ring buffer.
// If we increase the scrollback, we perform a full memory copy. For small
// scrollback, this is pretty cheap. For large (or infinite) scrollback,
// this starts to get pretty nasty. We should change this in the future to
// use a segmented list or something similar. I want to keep all the visible
// area contiguous so its not a simple drop-in. We can take a look at this
// one day.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const color = @import("color.zig");
const point = @import("point.zig");
const Selection = @import("Selection.zig");

const log = std.log.scoped(.screen);

/// A row is a set of cells.
pub const Row = []Cell;

/// Cursor represents the cursor state.
pub const Cursor = struct {
    // x, y where the cursor currently exists (0-indexed). This x/y is
    // always the offset in the active area.
    x: usize = 0,
    y: usize = 0,

    // pen is the current cell styling to apply to new cells.
    pen: Cell = .{ .char = 0 },

    // The last column flag (LCF) used to do soft wrapping.
    pending_wrap: bool = false,
};

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
        underline: u1 = 0,
        inverse: u1 = 0,

        /// If 1, this line is soft-wrapped. Only the last cell in a row
        /// should have this set. The first cell of the next row is actually
        /// part of this row in raw input.
        wrap: u1 = 0,
    } = .{},

    /// True if the cell should be skipped for drawing
    pub fn empty(self: Cell) bool {
        return self.char == 0;
    }
};

pub const RowIterator = struct {
    screen: *const Screen,
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

    // TODO: others
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
        return switch (self) {
            // The max of the screen is "bottom" so that we don't read
            // past the pre-allocated space.
            .screen => screen.bottom,
            .viewport => screen.rows,
            .active => screen.rows,
            .history => screen.bottomOffset(),
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

/// Each screen maintains its own cursor state.
cursor: Cursor = .{},

/// Saved cursor saved with DECSC (ESC 7).
saved_cursor: Cursor = .{},

/// The full list of rows, including any scrollback.
storage: []Cell,

/// The top and bottom of the scroll area. The first visible row if the terminal
/// window were scrolled all the way to the top. The last visible row if the
/// terminal were scrolled all the way to the bottom.
top: usize,
bottom: usize,

/// The offset of the visible area within the storage. This is from the
/// "top" field. So the actual index of the first row is
/// `storage[top + visible_offset]`.
visible_offset: usize,

/// The maximum number of lines that are available in scrollback. This
/// is in addition to the number of visible rows.
max_scrollback: usize,

/// The number of rows and columns in the visible space.
rows: usize,
cols: usize,

/// Initialize a new screen.
pub fn init(
    alloc: Allocator,
    rows: usize,
    cols: usize,
    max_scrollback: usize,
) !Screen {
    // Allocate enough storage to cover every row and column in the visible
    // area. This wastes some up front memory but saves allocations later.
    // TODO: dynamically allocate scrollback
    const buf = try alloc.alloc(Cell, (rows + max_scrollback) * cols);
    std.mem.set(Cell, buf, .{ .char = 0 });

    return Screen{
        .cursor = .{},
        .storage = buf,
        .top = 0,
        .bottom = rows,
        .visible_offset = 0,
        .max_scrollback = max_scrollback,
        .rows = rows,
        .cols = cols,
    };
}

pub fn deinit(self: *Screen, alloc: Allocator) void {
    alloc.free(self.storage);
    self.* = undefined;
}

/// This returns true if the viewport is anchored at the bottom currently.
pub fn viewportIsBottom(self: Screen) bool {
    return self.visible_offset == self.bottomOffset();
}

fn bottomOffset(self: Screen) usize {
    return self.bottom - self.rows;
}

/// Returns an iterator that can be used to iterate over all of the rows
/// from index zero of the given row index type. This can therefore iterate
/// from row 0 of the active area, history, viewport, etc.
pub fn rowIterator(self: *const Screen, tag: RowIndexTag) RowIterator {
    return .{ .screen = self, .tag = tag };
}

/// Region gets the contiguous portions of memory that constitute an
/// entire region. This is an efficient way to clear regions, for example
/// since you can memcpy directly into it.
///
/// This has two elements because internally we use a ring buffer and
/// so any region can be split into two if it crosses the ring buffer
/// boundary.
pub fn region(self: *const Screen, tag: RowIndexTag) [2][]Cell {
    const max_len = tag.maxLen(self);
    if (max_len == 0) {
        // This region is disabled or empty
        return .{ self.storage[0..0], self.storage[0..0] };
    }

    const top = self.rowIndex(tag.index(0));
    const bot = self.rowIndex(tag.index(max_len - 1));

    // The bottom and top are available in one contiguous slice.
    if (bot >= top) {
        return .{
            self.storage[top .. bot + self.cols],
            self.storage[0..0], // just so its a valid slice, but zero length
        };
    }

    // The bottom and top are split into two slices, so we slice to the
    // bottom of the storage, then from the top.
    return .{
        self.storage[top..self.storage.len],
        self.storage[0 .. bot + self.cols],
    };
}

/// Get a single row in the active area by index (0-indexed).
pub fn getRow(self: Screen, idx: RowIndex) Row {
    // Get the index of the first byte of the the row at index.
    const real_idx = self.rowIndex(idx);

    // The storage is sliced to return exactly the number of columns.
    return self.storage[real_idx .. real_idx + self.cols];
}

/// Get a single cell in the active area. row and col are 0-indexed.
pub fn getCell(self: Screen, row: usize, col: usize) *Cell {
    assert(row < self.rows);
    assert(col < self.cols);
    const row_idx = self.rowIndex(.{ .active = row });
    return &self.storage[row_idx + col];
}

/// Returns the index for the given row (0-indexed) into the underlying
/// storage array. The row is 0-indexed from the top of the screen.
fn rowIndex(self: *const Screen, idx: RowIndex) usize {
    const y = switch (idx) {
        .screen => |y| y: {
            assert(y < RowIndexTag.screen.maxLen(self));
            break :y y;
        },

        .viewport => |y| y: {
            assert(y < RowIndexTag.viewport.maxLen(self));
            break :y y + self.visible_offset;
        },

        .active => |y| y: {
            assert(y < RowIndexTag.active.maxLen(self));
            break :y self.bottomOffset() + y;
        },

        .history => |y| y: {
            assert(y < RowIndexTag.history.maxLen(self));
            break :y y;
        },
    };

    const val = (self.top + y) * self.cols;
    if (val < self.storage.len) return val;
    return val - self.storage.len;
}

/// Returns the total number of rows in the screen.
inline fn totalRows(self: Screen) usize {
    return self.storage.len / self.cols;
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
        .top => self.visible_offset = 0,

        // Calc the bottom by going from top of scrollback (self.top)
        // to the end of the storage, then subtract the number of visible
        // rows.
        .bottom => self.visible_offset = self.bottom - self.rows,

        // TODO: deltas greater than the entire scrollback
        .delta => |delta| self.scrollDelta(delta, true),
        .delta_no_grow => |delta| self.scrollDelta(delta, false),
    }
}

fn scrollDelta(self: *Screen, delta: isize, grow: bool) void {
    // log.info("offsets before: top={} bottom={} visible={}", .{
    //     self.top,
    //     self.bottom,
    //     self.visible_offset,
    // });
    // defer {
    //     log.info("offsets after: top={} bottom={} visible={}", .{
    //         self.top,
    //         self.bottom,
    //         self.visible_offset,
    //     });
    // }

    // If we're scrolling up, then we just subtract and we're done.
    if (delta < 0) {
        self.visible_offset -|= @intCast(usize, -delta);
        return;
    }

    // If we're scrolling down, we have more work to do beacuse we
    // need to determine if we're overwriting our scrollback.
    self.visible_offset +|= @intCast(usize, delta);
    if (grow) {
        self.bottom +|= @intCast(usize, delta);
    } else {
        // If we're not growing, then we want to ensure we don't scroll
        // off the bottom. Calculate the number of rows we can see. If we
        // can see less than the number of rows we have available, then scroll
        // back a bit.
        const visible_bottom = self.visible_offset + self.rows;
        if (visible_bottom > self.bottom) {
            self.visible_offset = self.bottom - self.rows;

            // We can also fast-track this case because we know we won't
            // be overlapping at all so we can return immediately.
            return;
        }
    }

    // TODO: can optimize scrollback = 0

    // Determine if we need to clear rows.
    assert(@mod(self.storage.len, self.cols) == 0);
    const storage_rows = self.storage.len / self.cols;
    const visible_zero = self.top + self.visible_offset;
    const rows_overlapped = if (visible_zero >= storage_rows) overlap: {
        // We're wrapping from the top of the visible area. In this
        // scenario, we just check that we have enough space from
        // our true visible top to zero.
        const visible_top = visible_zero - storage_rows;
        const rows_available = self.top - visible_top;
        if (rows_available >= self.rows) return;

        // We overlap our missing rows
        break :overlap self.rows - rows_available;
    } else overlap: {
        // First check: if we have enough space in the storage buffer
        // FORWARD to accomodate all our rows, then we're fine.
        const rows_forward = storage_rows - (self.top + self.visible_offset);
        if (rows_forward >= self.rows) return;

        // Second check: if we have enough space PRIOR to zero when
        // wrapped, then we're fine.
        const rows_wrapped = self.rows - rows_forward;
        if (rows_wrapped < self.top) return;

        // We need to clear the rows in the overlap and move the top
        // of the scrollback buffer.
        break :overlap rows_wrapped - self.top;
    };

    // If we are growing, then we clear the overlap and reset zero
    if (grow) {
        // Clear our overlap
        const clear_start = self.top * self.cols;
        const clear_end = clear_start + (rows_overlapped * self.cols);
        std.mem.set(Cell, self.storage[clear_start..clear_end], .{ .char = 0 });

        // Move to accomodate overlap. This deletes scrollback.
        self.top = @mod(self.top + rows_overlapped, storage_rows);

        // The new bottom is right up against the new top since we're using
        // the full buffer. The bottom is therefore the full size of the storage.
        self.bottom = storage_rows;
    }

    // Move back the number of overlapped
    self.visible_offset -= rows_overlapped;
}

/// Copy row at src to dst.
pub fn copyRow(self: *Screen, dst: usize, src: usize) void {
    const src_row = self.getRow(.{ .active = src });
    const dst_row = self.getRow(.{ .active = dst });
    std.mem.copy(Cell, dst_row, src_row);
}

/// Resize the screen. The rows or cols can be bigger or smaller. This
/// function can only be used to resize the viewport. The scrollback size
/// (in lines) can't be changed. But due to the resize, more or less scrollback
/// "space" becomes available due to the width of lines.
///
/// Due to the internal representation of a screen, this usually involves a
/// significant amount of copying compared to any other operations.
///
/// This will trim data if the size is getting smaller. This will reflow the
/// soft wrapped text.
pub fn resize(self: *Screen, alloc: Allocator, rows: usize, cols: usize) !void {
    defer {
        assert(self.cursor.x < self.cols);
        assert(self.cursor.y < self.rows);
        assert(self.rows == rows);
        assert(self.cols == cols);
    }

    // If the rows increased, we alloc space for the new rows (w/ existing cols)
    // and move the viewport such that the bottom is in view.
    if (rows > self.rows) {
        var storage = try alloc.alloc(
            Cell,
            (rows + self.max_scrollback) * self.cols,
        );

        // Copy our screen into the new storage area. Since we're growing
        // rows, we know that the full buffer will fit so we copy it in
        // order.
        const reg = self.region(.screen);
        std.mem.copy(Cell, storage, reg[0]);
        std.mem.copy(Cell, storage[reg[0].len..], reg[1]);
        std.mem.set(Cell, storage[reg[0].len + reg[1].len ..], .{ .char = 0 });

        // Modify our storage, our lines have grown
        alloc.free(self.storage);
        self.storage = storage;

        // Fix our row count
        self.rows = rows;

        // Store our visible offset so we can move our cursor accordingly.
        const old_offset = self.visible_offset;

        // Top is now 0 because we reoriented the ring buffer to be ordered.
        // Bottom must be at least "rows" since we always show at least that
        // much in the viewport.
        self.top = 0;
        self.bottom = @maximum(rows, self.bottom);
        self.scroll(.{ .bottom = {} });

        // Move our cursor to account for the new rows. The old offset
        // should always be bigger (or the same) than the new offset since
        // we are adding rows.
        self.cursor.y += old_offset - self.visible_offset;
    }

    // If our columns increased, we alloc space for the new column width
    // and go through each row and reflow if necessary.
    if (cols > self.cols) {
        var storage = try alloc.alloc(
            Cell,
            (self.rows + self.max_scrollback) * cols,
        );
        std.mem.set(Cell, storage, .{ .char = 0 });

        // Convert our cursor coordinates to screen coordinates because
        // we may have to reflow the cursor if the line it is on is unwrapped.
        const cursor_pos = (point.Viewport{
            .x = self.cursor.x,
            .y = self.cursor.y,
        }).toScreen(self);

        // Nothing can fail from this point forward (no "try" expressions)
        // so replace our storage. We defer freeing the "old" value because
        // we need to access the old screen to copy.
        var old = self.*;
        defer {
            assert(old.storage.ptr != self.storage.ptr);
            alloc.free(old.storage);
        }
        self.storage = storage;
        self.cols = cols;

        // Whether we need to move the cursor or not
        var new_cursor: ?point.ScreenPoint = null;

        // Iterate over the screen since we need to check for reflow.
        var iter = old.rowIterator(.screen);
        var y: usize = 0;
        while (iter.next()) |row| {
            // No matter what we copy this row
            var new_row = self.getRow(.{ .screen = y });
            std.mem.copy(Cell, new_row, row);

            // We need to check if our cursor was on this line
            // and in the part that WAS copied. If so, we need to move it.
            if (cursor_pos.y == iter.value - 1) {
                assert(new_cursor == null); // should only happen once
                new_cursor = .{ .y = y, .x = cursor_pos.x };
            }

            // If no reflow, just keep going
            if (row[row.len - 1].attrs.wrap == 0) {
                y += 1;
                continue;
            }

            // We need to reflow. At this point things get a bit messy.
            // The goal is to keep the messiness of reflow down here and
            // only reloop when we're back to clean non-wrapped lines.

            // Mark the last element as not wrapped
            new_row[row.len - 1].attrs.wrap = 0;

            // We maintain an x coord so that we can set cursors properly
            var x: usize = row.len;
            new_row = new_row[x..];
            wrapping: while (iter.next()) |wrapped_row| {
                // Trim the row from the right so that we ignore all trailing
                // empty chars and don't wrap them.
                const trimmed_row = trim: {
                    var i: usize = wrapped_row.len;
                    while (i > 0) : (i -= 1) if (!wrapped_row[i - 1].empty()) break;
                    break :trim wrapped_row[0..i];
                };

                var wrapped_rem = trimmed_row;
                while (wrapped_rem.len > 0) {
                    // If the wrapped row fits nicely...
                    if (wrapped_rem.len <= new_row.len) {
                        // Copy the row
                        std.mem.copy(Cell, new_row, wrapped_rem);

                        // If our cursor is in this line, then we have to move it
                        // onto the new line because it got unwrapped.
                        if (cursor_pos.y == iter.value - 1 and new_cursor == null) {
                            new_cursor = .{ .y = y, .x = cursor_pos.x + x };
                        }

                        // If this row isn't also wrapped, we're done!
                        if (wrapped_rem[wrapped_rem.len - 1].attrs.wrap == 0) {
                            y += 1;

                            // If we were able to copy the entire row then
                            // we shortened the screen by one. We need to reflect
                            // this in our viewport.
                            if (wrapped_rem.len == trimmed_row.len and
                                self.visible_offset > 0)
                            {
                                self.visible_offset -= 1;
                                self.bottom -= 1;
                            }

                            break :wrapping;
                        }

                        // Wrapped again!
                        new_row[wrapped_rem.len - 1].attrs.wrap = 0;
                        new_row = new_row[wrapped_rem.len..];
                        x += wrapped_rem.len;
                        break;
                    }

                    // The row doesn't fit, meaning we have to soft-wrap the
                    // new row but probably at a diff boundary.
                    std.mem.copy(Cell, new_row, wrapped_rem[0..new_row.len]);
                    new_row[new_row.len - 1].attrs.wrap = 1;

                    // We still need to copy the remainder
                    wrapped_rem = wrapped_rem[new_row.len..];

                    // We need to check if our cursor was on this line
                    // and in the part that WAS copied. If so, we need to move it.
                    if (cursor_pos.y == iter.value - 1 and
                        cursor_pos.x < new_row.len)
                    {
                        assert(new_cursor == null); // should only happen once
                        new_cursor = .{ .y = y, .x = x + cursor_pos.x };
                    }

                    // Move to a new line in our new screen
                    y += 1;
                    x = 0;
                    new_row = self.getRow(.{ .screen = y });
                }
            }
        }

        // If we have a new cursor, we need to convert that to a viewport
        // point and set it up.
        if (new_cursor) |pos| {
            const viewport_pos = pos.toViewport(self);
            self.cursor.x = viewport_pos.x;
            self.cursor.y = viewport_pos.y;
        }
    }

    // If our rows got smaller, we trim the scrollback.
    if (rows < self.rows) {
        var storage = try alloc.alloc(
            Cell,
            (rows + self.max_scrollback) * self.cols,
        );

        // Get the slices for our full screen. We only copy the end of it
        // that fits into our new memory region. We know we have the same
        // number of columns in this block so we can just copy as-is.
        const reg = self.region(.screen);

        // Trim the empty space off the end. The "end" might go into
        // "top" since bottom may be empty or only implies the wraparound
        // on the ring buffer.
        const top = reg[0];
        const bot = reg[1];
        const bot_trimmed = trim: {
            var i: usize = bot.len;
            while (i > 0) : (i -= 1) if (!bot[i - 1].empty()) break;
            i += self.cols - @mod(i, self.cols);
            i = @minimum(bot.len, i);
            break :trim bot[0..i];
        };
        const top_trimmed = if (bot.len > 0 and bot_trimmed.len == bot.len) noop: {
            // We do nothing here because it means that we hit real content
            // in the "bottom" so we don't want to trim zeros off the top
            // when they might actually be useful.
            break :noop top;
        } else trim: {
            var i: usize = top.len;
            while (i > 0) : (i -= 1) if (!top[i - 1].empty()) break;
            i += self.cols - @mod(i, self.cols);
            i = @minimum(top.len, i);
            break :trim top[0..i];
        };

        // The trimmed also have to be cleanly divisible by rows since
        // the copy and other math below depends on this invariant.
        assert(@mod(bot_trimmed.len, self.cols) == 0);
        assert(@mod(top_trimmed.len, self.cols) == 0);

        // Copy the top and bottom into the storage
        const bot_len = @minimum(bot_trimmed.len, storage.len);
        const top_len = @minimum(top_trimmed.len, storage.len - bot_len);
        std.mem.copy(Cell, storage, top_trimmed[top_trimmed.len - top_len ..]);
        std.mem.copy(Cell, storage[top_len..], bot_trimmed[bot_trimmed.len - bot_len ..]);
        std.mem.set(Cell, storage[top_len + bot_len ..], .{ .char = 0 });

        // Calculate the number of rows we copied since this will be
        // our new "bottom". This should always divide cleanly because
        // our cols haven't changed.
        assert(@mod(top_len + bot_len, self.cols) == 0);
        const copied_rows = (top_len + bot_len) / self.cols;

        // Modify our storage
        alloc.free(self.storage);
        self.storage = storage;

        // If our cursor was past the end of our old value, we pull it back.
        if (self.cursor.y >= rows) {
            self.cursor.y -= self.rows - rows;
        }

        // Fix our row count
        self.rows = rows;

        // Top is now 0 because we reoriented the ring buffer to be ordered.
        // Bottom must be at least "rows" since we always show at least that
        // much in the viewport.
        self.top = 0;
        self.bottom = @maximum(rows, copied_rows);
        //log.warn("bot={} top={} copied={}", .{ bot_len, top_len, copied_rows });
        //log.warn("BOTTOM={}", .{self.bottom});
        self.scroll(.{ .bottom = {} });
    }

    // If our cols got smaller, we have to reflow text. This is the worst
    // possible case because we can't do any easy trick sto get reflow,
    // we just have to iterate over the screen and "print", wrapping as
    // needed.
    if (cols < self.cols) {
        var storage = try alloc.alloc(
            Cell,
            (self.rows + self.max_scrollback) * cols,
        );
        std.mem.set(Cell, storage, .{ .char = 0 });

        // Convert our cursor coordinates to screen coordinates because
        // we may have to reflow the cursor if the line it is on is moved.
        var cursor_pos = (point.Viewport{
            .x = self.cursor.x,
            .y = self.cursor.y,
        }).toScreen(self);

        // Nothing can fail from this point forward (no "try" expressions)
        // so replace our storage. We defer freeing the "old" value because
        // we need to access the old screen to copy.
        var old = self.*;
        defer {
            assert(old.storage.ptr != self.storage.ptr);
            alloc.free(old.storage);
        }
        self.storage = storage;
        self.cols = cols;

        // Whether we need to move the cursor or not
        var new_cursor: ?point.ScreenPoint = null;

        // Iterate over the screen since we need to check for reflow.
        var iter = old.rowIterator(.screen);
        var x: usize = 0;
        var y: usize = 0;
        while (iter.next()) |row| {
            // Trim the row from the right so that we ignore all trailing
            // empty chars and don't wrap them.
            const trimmed_row = trim: {
                var i: usize = row.len;
                while (i > 0) {
                    if (!row[i - 1].empty()) break;
                    i -= 1;
                }

                break :trim row[0..i];
            };

            // Copy all the cells into our row.
            for (trimmed_row) |cell, i| {
                // Soft wrap if we have to
                if (x == self.cols) {
                    var last_cell = self.getCell(y, x - 1);
                    last_cell.attrs.wrap = 1;
                    x = 0;
                    y += 1;
                }

                // If our y is more than our rows, we need to scroll
                if (y >= self.rows) {
                    self.scroll(.{ .delta = 1 });
                    y = self.rows - 1;
                    x = 0;
                }

                // If our cursor is on this point, we need to move it.
                if (cursor_pos.y == iter.value - 1 and
                    cursor_pos.x == i)
                {
                    assert(new_cursor == null);
                    new_cursor = .{ .x = x, .y = self.visible_offset + y };
                }

                // Copy the old cell, unset the old wrap state
                // log.warn("y={} x={} rows={}", .{ y, x, self.rows });
                var new_cell = self.getCell(y, x);
                new_cell.* = cell;
                new_cell.attrs.wrap = 0;

                // Next
                x += 1;
            }

            // If our cursor is on this line but not in a content area,
            // then we just set it to be at the end.
            if (cursor_pos.y == iter.value - 1 and
                cursor_pos.x >= trimmed_row.len)
            {
                assert(new_cursor == null);
                new_cursor = .{
                    .x = @minimum(cursor_pos.x, self.cols - 1),
                    .y = self.visible_offset + y,
                };
            }

            // If we aren't wrapping, then move to the next row
            if (trimmed_row.len == 0 or
                trimmed_row[trimmed_row.len - 1].attrs.wrap == 0)
            {
                y += 1;
                x = 0;
            }
        }

        // If we have a new cursor, we need to convert that to a viewport
        // point and set it up.
        if (new_cursor) |pos| {
            const viewport_pos = pos.toViewport(self);
            self.cursor.x = viewport_pos.x;
            self.cursor.y = viewport_pos.y;
        } else {
            // TODO: why is this necessary? Without this, neovim will
            // crash when we shrink the window to the smallest size
            self.cursor.x = @minimum(self.cursor.x, self.cols - 1);
            self.cursor.y = @minimum(self.cursor.y, self.rows - 1);
        }
    }
}

/// Resize the screen without any reflow. In this mode, columns/rows will
/// be truncated as they are shrunk. If they are grown, the new space is filled
/// with zeros.
pub fn resizeWithoutReflow(self: *Screen, alloc: Allocator, rows: usize, cols: usize) !void {
    // Resize without reflow not supported for now with scrollback.
    assert(self.max_scrollback == 0);

    // Make a copy so we can access the old indexes.
    const old = self.*;

    // Reallocate the storage
    self.storage = try alloc.alloc(Cell, (rows + self.max_scrollback) * cols);
    defer alloc.free(old.storage);
    std.mem.set(Cell, self.storage, .{ .char = 0 });
    self.top = 0;
    self.bottom = rows;
    self.rows = rows;
    self.cols = cols;

    // Move our cursor if we have to so it stays on the screen.
    self.cursor.x = @minimum(self.cursor.x, self.cols - 1);
    self.cursor.y = @minimum(self.cursor.y, self.rows - 1);

    // If we're increasing height, then copy all rows (start at 0).
    // Otherwise start at the latest row that includes the bottom row,
    // aka strip the top.
    var y: usize = if (rows >= old.rows) 0 else old.rows - rows;
    const start = y;
    const col_end = @minimum(old.cols, cols);
    while (y < old.rows) : (y += 1) {
        // Copy the old row into the new row, just losing the columsn
        // if we got thinner.
        const old_row = old.getRow(.{ .viewport = y });
        const new_row = self.getRow(.{ .viewport = y - start });
        std.mem.copy(Cell, new_row, old_row[0..col_end]);

        // If our new row is wider, then we copy zeroes into the rest.
        if (new_row.len > old_row.len) {
            std.mem.set(Cell, new_row[old_row.len..], .{ .char = 0 });
        }
    }

    // If we grew rows, then set the remaining data to zero.
    if (rows > old.rows) {
        std.mem.set(Cell, self.storage[self.rowIndex(.{ .viewport = old.rows })..], .{ .char = 0 });
    }
}

/// Returns the raw text associated with a selection. This will unwrap
/// soft-wrapped edges. The returned slice is owned by the caller.
pub fn selectionString(self: Screen, alloc: Allocator, sel: Selection) ![:0]const u8 {
    // Get the slices for the string
    const slices = self.selectionSlices(sel);

    // We can now know how much space we'll need to store the string. We loop
    // over and UTF8-encode and calculate the exact size required. We will be
    // off here by at most "newlines" values in the worst case that every
    // single line is soft-wrapped.
    const newlines = @divFloor(slices.top.len + slices.bot.len, self.cols) + 1;
    const chars = chars: {
        var count: usize = 0;
        const arr = [_][]Cell{ slices.top, slices.bot };
        for (arr) |slice| {
            for (slice) |cell| {
                var buf: [4]u8 = undefined;
                const char = if (cell.char > 0) cell.char else ' ';
                count += try std.unicode.utf8Encode(@intCast(u21, char), &buf);
            }
        }

        break :chars count;
    };
    const buf = try alloc.alloc(u8, chars + newlines + 1);
    errdefer alloc.free(buf);

    var i: usize = 0;
    for (slices.top) |cell, idx| {
        // If our index cleanly divides into the col count then we're
        // at a newline and we add it.
        if (idx > 0 and
            @mod(idx + slices.top_offset, self.cols) == 0 and
            slices.top[idx - 1].attrs.wrap == 0)
        {
            buf[i] = '\n';
            i += 1;
        }

        const char = if (cell.char > 0) cell.char else ' ';
        i += try std.unicode.utf8Encode(@intCast(u21, char), buf[i..]);
    }

    for (slices.bot) |cell, idx| {
        // We don't use "top_offset" here because the bot by definition
        // is never offset, it always starts at index 0 so we can just check
        // the index directly.
        if (@mod(idx, self.cols) == 0) {
            // Determine if we soft-wrapped. For the bottom slice this is
            // a bit unique because if we're at idx 0, we actually need to
            // check the end of the top.
            const wrapped = if (idx > 0)
                slices.bot[idx - 1].attrs.wrap == 1
            else
                slices.top[slices.top.len - 1].attrs.wrap == 1;

            if (!wrapped) {
                buf[i] = '\n';
                i += 1;
            }
        }

        const char = if (cell.char > 0) cell.char else ' ';
        i += try std.unicode.utf8Encode(@intCast(u21, char), buf[i..]);
    }

    // Add null termination
    buf[i] = 0;

    // Realloc so our free length is exactly correct
    const result = try alloc.realloc(buf, i + 1);
    return result[0..i :0];
}

/// Returns the slices that make up the selection, in order. There are at most
/// two parts to handle the ring buffer. If the selection fits in one contiguous
/// slice, then the second slice will have a length of zero.
fn selectionSlices(self: Screen, sel: Selection) struct {
    // Top offset can be used to determine if a newline is required by
    // seeing if the cell index plus the offset cleanly divides by screen cols.
    top_offset: usize,
    top: []Cell,
    bot: []Cell,
} {
    // Note: this function is tested via selectionString

    assert(sel.start.y < self.totalRows());
    assert(sel.end.y < self.totalRows());
    assert(sel.start.x < self.cols);
    assert(sel.end.x < self.cols);

    // Get the true "top" and "bottom"
    const sel_top = sel.topLeft();
    const sel_bot = sel.bottomRight();
    const top = self.rowIndex(.{ .screen = sel_top.y });
    const bot = self.rowIndex(.{ .screen = sel_bot.y });

    // The bottom and top are available in one contiguous slice.
    if (bot >= top) {
        return .{
            .top_offset = sel_top.x,
            .top = self.storage[top + sel_top.x .. bot + sel_bot.x + 1],
            .bot = self.storage[0..0], // just so its a valid slice, but zero length
        };
    }

    // The bottom and top are split into two slices, so we slice to the
    // bottom of the storage, then from the top.
    return .{
        .top_offset = sel_top.x,
        .top = self.storage[top + sel_top.x .. self.storage.len],
        .bot = self.storage[0 .. bot + sel_bot.x + 1],
    };
}

/// Turns the screen into a string. Different regions of the screen can
/// be selected using the "tag", i.e. if you want to output the viewport,
/// the scrollback, the full screen, etc.
pub fn testString(self: Screen, alloc: Allocator, tag: RowIndexTag) ![]const u8 {
    const buf = try alloc.alloc(u8, self.storage.len + self.rows + 1);

    var i: usize = 0;
    var y: usize = 0;
    var rows = self.rowIterator(tag);
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
/// each row. If a line is longer than the available columns, soft-wrapping
/// will occur.
fn testWriteString(self: *Screen, text: []const u8) void {
    var y: usize = 0;
    var x: usize = 0;
    for (text) |c| {
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
            row[x - 1].attrs.wrap = 1;
            y += 1;
            x = 0;
            if (y >= self.rows) {
                y -= 1;
                self.scroll(.{ .delta = 1 });
            }
            row = self.getRow(.{ .active = y });
        }

        row[x].char = @intCast(u32, c);
        x += 1;
    }
}

test "Screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);

    // Sanity check that our test helpers work
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
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
        try testing.expectEqual(row.ptr, row_other.ptr);
        count += 1;
    }

    // Should go through all rows
    try testing.expectEqual(@as(usize, 3), count);

    // Should be able to easily clear screen
    const reg = s.region(.viewport);
    std.mem.set(Cell, reg[0], .{ .char = 'A' });
    std.mem.set(Cell, reg[1], .{ .char = 'A' });
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("AAAAA\nAAAAA\nAAAAA", contents);
    }
}

test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    try testing.expect(s.viewportIsBottom());

    // Scroll down, should still be bottom
    s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());

    // Test our row index
    try testing.expectEqual(@as(usize, 5), s.rowIndex(.{ .active = 0 }));
    try testing.expectEqual(@as(usize, 10), s.rowIndex(.{ .active = 1 }));
    try testing.expectEqual(@as(usize, 0), s.rowIndex(.{ .active = 2 }));

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

// TODO
// test "Screen: scrolling more than size" {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//
//     var s = try init(alloc, 3, 5, 3);
//     defer s.deinit(alloc);
//     s.testWriteString("1ABCD\n2EFGH\n3IJKL");
//
//     try testing.expect(s.viewportIsBottom());
//
//     // Scroll down, should still be bottom
//     s.scroll(.{ .delta = 7 });
//     try testing.expect(s.viewportIsBottom());
//
//     // Test our row index
//     try testing.expectEqual(@as(usize, 5), s.rowIndex(0));
//     try testing.expectEqual(@as(usize, 10), s.rowIndex(1));
//     try testing.expectEqual(@as(usize, 15), s.rowIndex(2));
// }

test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
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
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta = 1 });

    // Test our row index
    try testing.expectEqual(@as(usize, 5), s.rowIndex(.{ .active = 0 }));
    try testing.expectEqual(@as(usize, 10), s.rowIndex(.{ .active = 1 }));
    try testing.expectEqual(@as(usize, 15), s.rowIndex(.{ .active = 2 }));

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
    const reg = s.region(.active);
    std.mem.set(Cell, reg[0], .{ .char = 0 });
    std.mem.set(Cell, reg[1], .{ .char = 0 });
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
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_no_grow = 1 });

    {
        // Test our contents
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: history region with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 0);
    defer s.deinit(alloc);

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
    const reg = s.region(.history);
    try testing.expect(reg[0].len == 0);
    try testing.expect(reg[1].len == 0);
}

test "Screen: history region with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 2);
    defer s.deinit(alloc);

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

    // Verify history region
    const reg = s.region(.history);
    try testing.expect(reg[0].len > 0);
    try testing.expect(reg[1].len >= 0);

    {
        var contents = try s.testString(alloc, .history);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: row copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Copy
    s.scroll(.{ .delta = 1 });
    s.copyRow(2, 0);

    // Test our contents
    var contents = try s.testString(alloc, .viewport);
    defer alloc.free(contents);
    try testing.expectEqualStrings("2EFGH\n3IJKL\n2EFGH", contents);
}

test "Screen: selectionString" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD2EFGH3IJKL";
    s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        });
        defer alloc.free(contents);
        const expected = "2EFGH3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wrap around" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll down, should still be bottom, but should wrap because
    // we're out of space.
    s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());
    try testing.expectEqual(@as(usize, 0), s.rowIndex(.{ .active = 2 }));
    s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize more rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(alloc, 10, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(alloc, 10, 5);
    try testing.expectEqual(@as(usize, 20), s.totalRows());

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Set our cursor to be on the "4"
    s.cursor.x = 0;
    s.cursor.y = 1;
    try testing.expectEqual(@as(u32, '4'), s.getCell(s.cursor.y, s.cursor.x).char);

    // Resize
    try s.resize(alloc, 10, 5);
    try testing.expectEqual(@as(usize, 15), s.totalRows());

    // Cursor should still be on the "4"
    try testing.expectEqual(@as(u32, '4'), s.getCell(s.cursor.y, s.cursor.x).char);
    // s.cursor.x = 0;
    // s.cursor.y = 1;
    //try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(alloc, 3, 10);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more cols with reflow that fits full width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD2EFGH\n3IJKL";
    s.testWriteString(str);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursor.x = 0;
    s.cursor.y = 1;
    try testing.expectEqual(@as(u32, '2'), s.getCell(s.cursor.y, s.cursor.x).char);

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(alloc, 3, 10);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

test "Screen: resize more cols with reflow that ends in newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 6, 0);
    defer s.deinit(alloc);
    const str = "1ABCD2EFGH\n3IJKL";
    s.testWriteString(str);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD2\nEFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Let's put our cursor on the last row
    s.cursor.x = 0;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, '3'), s.getCell(s.cursor.y, s.cursor.x).char);

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(alloc, 3, 10);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should still be on the 3
    try testing.expectEqual(@as(u32, '3'), s.getCell(s.cursor.y, s.cursor.x).char);
}

test "Screen: resize more cols with reflow that forces more wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD2EFGH\n3IJKL";
    s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursor.x = 0;
    s.cursor.y = 1;
    try testing.expectEqual(@as(u32, '2'), s.getCell(s.cursor.y, s.cursor.x).char);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(alloc, 3, 7);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD2E\nFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

test "Screen: resize more cols with reflow that unwraps multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD2EFGH3IJKL";
    s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursor.x = 0;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, '3'), s.getCell(s.cursor.y, s.cursor.x).char);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(alloc, 3, 15);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD2EFGH3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 10), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

test "Screen: resize more cols with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD5EFGH";
    s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // // Set our cursor to be on the "5"
    s.cursor.x = 0;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, '5'), s.getCell(s.cursor.y, s.cursor.x).char);

    // Resize
    try s.resize(alloc, 3, 10);

    // Cursor should still be on the "5"
    log.warn("cursor={}", .{s.cursor});
    try testing.expectEqual(@as(u32, '5'), s.getCell(s.cursor.y, s.cursor.x).char);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(alloc, 1, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows moving cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);

    // Put our cursor on the last line
    s.cursor.x = 1;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, 'I'), s.getCell(s.cursor.y, s.cursor.x).char);

    // Resize
    try s.resize(alloc, 1, 5);

    // Cursor should be on the last line
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resize(alloc, 1, 5);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize
    try s.resize(alloc, 1, 5);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1AB\n2EF\n3IJ";
    s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(alloc, 3, 3);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less cols with reflow but row space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD";
    s.testWriteString(str);

    // Put our cursor on the end
    s.cursor.x = 4;
    s.cursor.y = 0;
    try testing.expectEqual(@as(u32, 'D'), s.getCell(s.cursor.y, s.cursor.x).char);

    try s.resize(alloc, 3, 3);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);
}

test "Screen: resize less cols with reflow with trimmed rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "3IJKL\n4ABCD\n5EFGH";
    s.testWriteString(str);
    try s.resize(alloc, 3, 3);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow with trimmed rows and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 1);
    defer s.deinit(alloc);
    const str = "3IJKL\n4ABCD\n5EFGH";
    s.testWriteString(str);
    try s.resize(alloc, 3, 3);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "4AB\nCD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// This seems like it should work fine but for some reason in practice
// in the initial implementation I found this bug! This is a regression
// test for that.
test "Screen: resize more rows then shrink again" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit(alloc);
    const str = "1ABC";
    s.testWriteString(str);

    // Grow
    try s.resize(alloc, 10, 5);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Shrink
    try s.resize(alloc, 3, 5);
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Grow again
    try s.resize(alloc, 10, 5);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resizeWithoutReflow(alloc, 10, 5);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resizeWithoutReflow(alloc, 2, 5);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resizeWithoutReflow(alloc, 3, 10);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit(alloc);
    const str = "1ABCD\n2EFGH\n3IJKL";
    s.testWriteString(str);
    try s.resizeWithoutReflow(alloc, 3, 4);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABC\n2EFG\n3IJK";
        try testing.expectEqualStrings(expected, contents);
    }
}
