const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const CircBuf = @import("../datastruct/main.zig").CircBuf;
const terminal = @import("main.zig");
const point = terminal.point;
const Page = terminal.Page;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;

pub const PageListSearch = struct {
    alloc: Allocator,

    /// The list we're searching.
    list: *PageList,

    /// The search term we're searching for.
    needle: []const u8,

    /// The window is our sliding window of pages that we're searching so
    /// we can handle boundary cases where a needle is partially on the end
    /// of one page and the beginning of the next.
    ///
    /// Note that we're not guaranteed to straddle exactly two pages. If
    /// the needle is large enough and/or the pages are small enough then
    /// the needle can straddle N pages. Additionally, pages aren't guaranteed
    /// to be equal size so we can't precompute the window size.
    window: SlidingWindow,

    pub fn init(
        alloc: Allocator,
        list: *PageList,
        needle: []const u8,
    ) !PageListSearch {
        var window = try CircBuf.init(alloc, 0);
        errdefer window.deinit();

        return .{
            .alloc = alloc,
            .list = list,
            .current = list.pages.first,
            .needle = needle,
            .window = window,
        };
    }

    pub fn deinit(self: *PageListSearch) void {
        _ = self;

        // TODO: deinit window
    }
};

/// Search pages via a sliding window. The sliding window always maintains
/// the invariant that data isn't pruned until we've searched it and
/// accounted for overlaps across pages.
const SlidingWindow = struct {
    /// The data buffer is a circular buffer of u8 that contains the
    /// encoded page text that we can use to search for the needle.
    data: DataBuf,

    /// The meta buffer is a circular buffer that contains the metadata
    /// about the pages we're searching. This usually isn't that large
    /// so callers must iterate through it to find the offset to map
    /// data to meta.
    meta: MetaBuf,

    /// Offset into data for our current state. This handles the
    /// situation where our search moved through meta[0] but didn't
    /// do enough to prune it.
    data_offset: usize = 0,

    const DataBuf = CircBuf(u8, 0);
    const MetaBuf = CircBuf(Meta, undefined);
    const Meta = struct {
        node: *PageList.List.Node,
        cell_map: Page.CellMap,

        pub fn deinit(self: *Meta) void {
            self.cell_map.deinit();
        }
    };

    pub fn initEmpty(alloc: Allocator) Allocator.Error!SlidingWindow {
        var data = try DataBuf.init(alloc, 0);
        errdefer data.deinit(alloc);

        var meta = try MetaBuf.init(alloc, 0);
        errdefer meta.deinit(alloc);

        return .{
            .data = data,
            .meta = meta,
        };
    }

    pub fn deinit(self: *SlidingWindow, alloc: Allocator) void {
        self.data.deinit(alloc);

        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit();
        self.meta.deinit(alloc);
    }

    /// Clear all data but retain allocated capacity.
    pub fn clearAndRetainCapacity(self: *SlidingWindow) void {
        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit();
        self.meta.clear();
        self.data.clear();
        self.data_offset = 0;
    }

    /// Search the window for the next occurrence of the needle. As
    /// the window moves, the window will prune itself while maintaining
    /// the invariant that the window is always big enough to contain
    /// the needle.
    pub fn next(self: *SlidingWindow, needle: []const u8) ?Selection {
        const data_len = self.data.len();
        if (data_len == 0) return null;
        const slices = self.data.getPtrSlice(
            self.data_offset,
            data_len - self.data_offset,
        );

        // Search the first slice for the needle.
        if (std.mem.indexOf(u8, slices[0], needle)) |idx| {
            return self.selection(idx, needle.len);
        }

        // TODO: search overlap

        // Search the last slice for the needle.
        if (std.mem.indexOf(u8, slices[1], needle)) |idx| {
            if (true) @panic("TODO: test");
            return self.selection(slices[0].len + idx, needle.len);
        }

        // No match. We keep `needle.len - 1` bytes available to
        // handle the future overlap case.
        var meta_it = self.meta.iterator(.reverse);
        prune: {
            var saved: usize = 0;
            while (meta_it.next()) |meta| {
                const needed = needle.len - 1 - saved;
                if (meta.cell_map.items.len >= needed) {
                    // We save up to this meta. We set our data offset
                    // to exactly where it needs to be to continue
                    // searching.
                    self.data_offset = meta.cell_map.items.len - needed;
                    break;
                }

                saved += meta.cell_map.items.len;
            } else {
                // If we exited the while loop naturally then we
                // never got the amount we needed and so there is
                // nothing to prune.
                assert(saved < needle.len - 1);
                break :prune;
            }

            const prune_count = self.meta.len() - meta_it.idx;
            if (prune_count == 0) {
                // This can happen if we need to save up to the first
                // meta value to retain our window.
                break :prune;
            }

            // We can now delete all the metas up to but NOT including
            // the meta we found through meta_it.
            meta_it = self.meta.iterator(.forward);
            var prune_data_len: usize = 0;
            for (0..prune_count) |_| {
                const meta = meta_it.next().?;
                prune_data_len += meta.cell_map.items.len;
                meta.deinit();
            }
            self.meta.deleteOldest(prune_count);
            self.data.deleteOldest(prune_data_len);
        }

        self.assertIntegrity();
        return null;
    }

    /// Return a selection for the given start and length into the data
    /// buffer and also prune the data/meta buffers if possible up to
    /// this start index.
    ///
    /// The start index is assumed to be relative to the offset. i.e.
    /// index zero is actually at `self.data[self.data_offset]`. The
    /// selection will account for the offset.
    fn selection(
        self: *SlidingWindow,
        start_offset: usize,
        len: usize,
    ) Selection {
        const start = start_offset + self.data_offset;
        assert(start < self.data.len());
        assert(start + len <= self.data.len());

        // meta_consumed is the number of bytes we've consumed in the
        // data buffer up to and NOT including the meta where we've
        // found our pin. This is important because it tells us the
        // amount of data we can safely deleted from self.data since
        // we can't partially delete a meta block's data. (The partial
        // amount is represented by self.data_offset).
        var meta_it = self.meta.iterator(.forward);
        var meta_consumed: usize = 0;
        const tl: Pin = pin(&meta_it, &meta_consumed, start);

        // Store the information required to prune later. We store this
        // now because we only want to prune up to our START so we can
        // find overlapping matches.
        const tl_meta_idx = meta_it.idx - 1;
        const tl_meta_consumed = meta_consumed;

        // We have to seek back so that we reinspect our current
        // iterator value again in case the start and end are in the
        // same segment.
        meta_it.seekBy(-1);
        const br: Pin = pin(&meta_it, &meta_consumed, start + len - 1);
        assert(meta_it.idx >= 1);

        // Our offset into the current meta block is the start index
        // minus the amount of data fully consumed. We then add one
        // to move one past the match so we don't repeat it.
        self.data_offset = start - tl_meta_consumed + 1;

        // meta_it.idx is br's meta index plus one (because the iterator
        // moves one past the end; we call next() one last time). So
        // we compare against one to check that the meta that we matched
        // in has prior meta blocks we can prune.
        if (tl_meta_idx > 0) {
            // Deinit all our memory in the meta blocks prior to our
            // match.
            const meta_count = tl_meta_idx;
            meta_it.reset();
            for (0..meta_count) |_| meta_it.next().?.deinit();
            if (comptime std.debug.runtime_safety) {
                assert(meta_it.idx == meta_count);
                assert(meta_it.next().?.node == tl.node);
            }
            self.meta.deleteOldest(meta_count);

            // Delete all the data up to our current index.
            assert(tl_meta_consumed > 0);
            self.data.deleteOldest(tl_meta_consumed);
        }

        self.assertIntegrity();
        return Selection.init(tl, br, false);
    }

    /// Convert a data index into a pin.
    ///
    /// The iterator and offset are both expected to be passed by
    /// pointer so that the pin can be efficiently called for multiple
    /// indexes (in order). See selection() for an example.
    ///
    /// Precondition: the index must be within the data buffer.
    fn pin(
        it: *MetaBuf.Iterator,
        offset: *usize,
        idx: usize,
    ) Pin {
        while (it.next()) |meta| {
            // meta_i is the index we expect to find the match in the
            // cell map within this meta if it contains it.
            const meta_i = idx - offset.*;
            if (meta_i >= meta.cell_map.items.len) {
                // This meta doesn't contain the match. This means we
                // can also prune this set of data because we only look
                // forward.
                offset.* += meta.cell_map.items.len;
                continue;
            }

            // We found the meta that contains the start of the match.
            const map = meta.cell_map.items[meta_i];
            return .{
                .node = meta.node,
                .y = map.y,
                .x = map.x,
            };
        }

        // Unreachable because it is a precondition that the index is
        // within the data buffer.
        unreachable;
    }

    /// Add a new node to the sliding window. This will always grow
    /// the sliding window; data isn't pruned until it is consumed
    /// via a search (via next()).
    pub fn append(
        self: *SlidingWindow,
        alloc: Allocator,
        node: *PageList.List.Node,
    ) Allocator.Error!void {
        // Initialize our metadata for the node.
        var meta: Meta = .{
            .node = node,
            .cell_map = Page.CellMap.init(alloc),
        };
        errdefer meta.deinit();

        // This is suboptimal but we need to encode the page once to
        // temporary memory, and then copy it into our circular buffer.
        // In the future, we should benchmark and see if we can encode
        // directly into the circular buffer.
        var encoded: std.ArrayListUnmanaged(u8) = .{};
        defer encoded.deinit(alloc);

        // Encode the page into the buffer.
        const page: *const Page = &meta.node.data;
        _ = page.encodeUtf8(
            encoded.writer(alloc),
            .{ .cell_map = &meta.cell_map },
        ) catch {
            // writer uses anyerror but the only realistic error on
            // an ArrayList is out of memory.
            return error.OutOfMemory;
        };
        assert(meta.cell_map.items.len == encoded.items.len);

        // Ensure our buffers are big enough to store what we need.
        try self.data.ensureUnusedCapacity(alloc, encoded.items.len);
        try self.meta.ensureUnusedCapacity(alloc, 1);

        // Append our new node to the circular buffer.
        try self.data.appendSlice(encoded.items);
        try self.meta.append(meta);

        self.assertIntegrity();
    }

    fn assertIntegrity(self: *const SlidingWindow) void {
        if (comptime !std.debug.runtime_safety) return;

        // Integrity check: verify our data matches our metadata exactly.
        var meta_it = self.meta.iterator(.forward);
        var data_len: usize = 0;
        while (meta_it.next()) |m| data_len += m.cell_map.items.len;
        assert(data_len == self.data.len());

        // Integrity check: verify our data offset is within bounds.
        assert(self.data_offset < self.data.len());
    }
};

test "SlidingWindow empty on init" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.initEmpty(alloc);
    defer w.deinit(alloc);
    try testing.expectEqual(0, w.data.len());
    try testing.expectEqual(0, w.meta.len());
}

test "SlidingWindow single append" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.initEmpty(alloc);
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // Imaginary needle for search
    const needle = "boo!";

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);

    // We should be able to find two matches.
    {
        const sel = w.next(needle).?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const sel = w.next(needle).?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    try testing.expect(w.next(needle) == null);
    try testing.expect(w.next(needle) == null);
}

test "SlidingWindow single append no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.initEmpty(alloc);
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // Imaginary needle for search
    const needle = "nope!";

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);

    // No matches
    try testing.expect(w.next(needle) == null);
    try testing.expect(w.next(needle) == null);

    // Should still keep the page
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.initEmpty(alloc);
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Imaginary needle for search
    const needle = "boo!";

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);
    try w.append(alloc, node.next.?);

    // Search should find two matches
    {
        const sel = w.next(needle).?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const sel = w.next(needle).?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    try testing.expect(w.next(needle) == null);
    try testing.expect(w.next(needle) == null);
}

test "SlidingWindow two pages match across boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.initEmpty(alloc);
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Imaginary needle for search
    const needle = "hello, world";

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);
    try w.append(alloc, node.next.?);

    // Search should find a match
    {
        const sel = w.next(needle).?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    try testing.expect(w.next(needle) == null);
    try testing.expect(w.next(needle) == null);

    // We shouldn't prune because we don't have enough space
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow two pages no match prunes first page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.initEmpty(alloc);
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);
    try w.append(alloc, node.next.?);

    // Imaginary needle for search. Doesn't match!
    const needle = "nope!";

    // Search should find nothing
    try testing.expect(w.next(needle) == null);
    try testing.expect(w.next(needle) == null);

    // We should've pruned our page because the second page
    // has enough text to contain our needle.
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match keeps both pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.initEmpty(alloc);
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);
    try w.append(alloc, node.next.?);

    // Imaginary needle for search. Doesn't match!
    var needle_list = std.ArrayList(u8).init(alloc);
    defer needle_list.deinit();
    try needle_list.appendNTimes('x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;

    // Search should find nothing
    try testing.expect(w.next(needle) == null);
    try testing.expect(w.next(needle) == null);

    // No pruning because both pages are needed to fit needle.
    try testing.expectEqual(2, w.meta.len());
}
