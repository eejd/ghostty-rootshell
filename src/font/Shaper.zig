//! This struct handles text shaping.
const Shaper = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const Atlas = @import("../Atlas.zig");
const Face = @import("main.zig").Face;
const Group = @import("main.zig").Group;
const GroupCache = @import("main.zig").GroupCache;
const Library = @import("main.zig").Library;
const Style = @import("main.zig").Style;
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.font_shaper);

/// The font group to use under the covers
group: *GroupCache,

/// The buffer used for text shaping. We reuse it across multiple shaping
/// calls to prevent allocations.
hb_buf: harfbuzz.Buffer,

pub fn init(group: *GroupCache) !Shaper {
    return Shaper{
        .group = group,
        .hb_buf = try harfbuzz.Buffer.create(),
    };
}

pub fn deinit(self: *Shaper) void {
    self.hb_buf.destroy();
}

/// Returns an iterator that returns one text run at a time for the
/// given terminal row. Note that text runs are are only valid one at a time
/// for a Shaper struct since they share state.
pub fn runIterator(self: *Shaper, row: terminal.Screen.Row) RunIterator {
    return .{ .shaper = self, .row = row };
}

/// Shape the given text run. The text run must be the immediately previous
/// text run that was iterated since the text run does share state with the
/// Shaper struct.
///
/// NOTE: there is no return value here yet because its still WIP
pub fn shape(self: Shaper, run: TextRun) void {
    const face = self.group.group.faceFromIndex(run.font_index);
    harfbuzz.shape(face.hb_font, self.hb_buf, null);

    const info = self.hb_buf.getGlyphInfos();
    const pos = self.hb_buf.getGlyphPositions() orelse return;

    // This is perhaps not true somewhere, but we currently assume it is true.
    // If it isn't true, I'd like to catch it and learn more.
    assert(info.len == pos.len);

    // log.warn("info={} pos={}", .{ info.len, pos.len });
    // for (info) |v, i| {
    //     log.warn("info {} = {}", .{ i, v });
    // }
}

/// A single text run. A text run is only valid for one Shaper and
/// until the next run is created.
pub const TextRun = struct {
    font_index: Group.FontIndex,
};

pub const RunIterator = struct {
    shaper: *Shaper,
    row: terminal.Screen.Row,
    i: usize = 0,

    pub fn next(self: *RunIterator, alloc: Allocator) !?TextRun {
        if (self.i >= self.row.len) return null;

        // Track the font for our curent run
        var current_font: Group.FontIndex = .{};

        // Reset the buffer for our current run
        self.shaper.hb_buf.reset();
        self.shaper.hb_buf.setContentType(.unicode);

        // Go through cell by cell and accumulate while we build our run.
        var j: usize = self.i;
        while (j < self.row.len) : (j += 1) {
            const cell = self.row[j];

            // Ignore tailing wide spacers, this will get fixed up by the shaper
            if (cell.empty() or cell.attrs.wide_spacer_tail) continue;

            const style: Style = if (cell.attrs.bold)
                .bold
            else
                .regular;

            // Determine the font for this cell
            const font_idx_opt = try self.shaper.group.indexForCodepoint(alloc, style, cell.char);
            const font_idx = font_idx_opt.?;
            //log.warn("char={x} idx={}", .{ cell.char, font_idx });
            if (j == self.i) current_font = font_idx;

            // If our fonts are not equal, then we're done with our run.
            if (font_idx.int() != current_font.int()) break;

            // Continue with our run
            self.shaper.hb_buf.add(cell.char, @intCast(u32, j));
        }

        // Finalize our buffer
        self.shaper.hb_buf.guessSegmentProperties();

        // Move our cursor
        self.i = j;

        return TextRun{ .font_index = current_font };
    }
};

test "run iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit(alloc);
        screen.testWriteString("ABCD");

        // Get our run iterator
        var shaper = testdata.shaper;
        var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit(alloc);
        screen.testWriteString("A😃D");

        // Get our run iterator
        var shaper = testdata.shaper;
        var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
        var count: usize = 0;
        while (try it.next(alloc)) |_| {
            count += 1;

            // All runs should be exactly length 1
            try testing.expectEqual(@as(u32, 1), shaper.hb_buf.getLength());
        }
        try testing.expectEqual(@as(usize, 3), count);
    }
}

test "shape" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F3FD, buf[buf_idx..]); // Medium skin tone

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit(alloc);
    screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = testdata.shaper;
    var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 3), shaper.hb_buf.getLength());
        shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

const TestShaper = struct {
    alloc: Allocator,
    shaper: Shaper,
    cache: *GroupCache,
    lib: Library,

    pub fn deinit(self: *TestShaper) void {
        self.shaper.deinit();
        self.cache.deinit(self.alloc);
        self.alloc.destroy(self.cache);
        self.lib.deinit();
    }
};

/// Helper to return a fully initialized shaper.
fn testShaper(alloc: Allocator) !TestShaper {
    const testFont = @import("test.zig").fontRegular;
    const testEmoji = @import("test.zig").fontEmoji;

    var lib = try Library.init();
    errdefer lib.deinit();

    var cache_ptr = try alloc.create(GroupCache);
    errdefer alloc.destroy(cache_ptr);
    cache_ptr.* = try GroupCache.init(alloc, try Group.init(alloc));
    errdefer cache_ptr.*.deinit(alloc);

    // Setup group
    try cache_ptr.group.addFace(alloc, .regular, try Face.init(lib, testFont, .{ .points = 12 }));
    try cache_ptr.group.addFace(alloc, .regular, try Face.init(lib, testEmoji, .{ .points = 12 }));

    var shaper = try init(cache_ptr);
    errdefer shaper.deinit();

    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .cache = cache_ptr,
        .lib = lib,
    };
}
