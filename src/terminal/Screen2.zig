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

const color = @import("color.zig");
const CircBuf = @import("circ_buf.zig").CircBuf;

const log = std.log.scoped(.screen);

/// This is a single item within the storage buffer. We use a union to
/// have different types of data in a single contiguous buffer.
///
/// Note: the union is extern so that it follows the same memory layout
/// semantics as C, which allows us to have a tightly packed union.
const StorageCell = extern union {
    row_header: RowHeader,
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
const Cell = struct {
    /// The primary unicode codepoint for this cell. Most cells (almost all)
    /// contain exactly one unicode codepoint. However, it is possible for
    /// cells to contain multiple if multiple codepoints are used to create
    /// a single grapheme cluster.
    ///
    /// In the case multiple codepoints make up a single grapheme, the
    /// additional codepoints can be looked up in the hash map on the
    /// Screen. Since multi-codepoints graphemes are rare, we don't want to
    /// waste memory for every cell, so we use a side lookup for it.
    char: u32,

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
    const buf_size = (rows + @minimum(max_scrollback, rows)) * (cols + 1);

    return Screen{
        .alloc = alloc,
        .storage = try StorageBuf.init(alloc, buf_size),
        .rows = rows,
        .cols = cols,
        .max_scrollback = max_scrollback,
    };
}

pub fn deinit(self: *Screen) void {
    self.storage.deinit(self.alloc);
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
}
