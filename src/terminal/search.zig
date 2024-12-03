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

/// The sliding window of the pages we're searching. The window is always
/// big enough so that the needle can fit in it.
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

        // No match. Clear everything.
        self.clearAndRetainCapacity();
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

        var meta_it = self.meta.iterator(.forward);
        const tl: Pin = pin(&meta_it, start);

        // We have to seek back so that we reinspect our current
        // iterator value again in case the start and end are in the
        // same segment.
        meta_it.seekBy(-1);
        const br: Pin = pin(&meta_it, start + len - 1);
        assert(meta_it.idx >= 1);

        // meta_it.idx is now the index after the br pin. We can
        // safely prune our data up to this index. (It is after
        // because next() is called at least once).
        const br_meta_idx: usize = meta_it.idx - 1;
        meta_it.reset();
        var offset: usize = 0;
        while (meta_it.next()) |meta| {
            const meta_idx = start - offset;
            if (meta_idx >= meta.cell_map.items.len) {
                // Prior to our matches, we can prune it.
                offset += meta.cell_map.items.len;
                meta.deinit();
            }

            assert(meta_it.idx == br_meta_idx + 1);
            break;
        }

        // If we have metas to prune, then prune them. They should be
        // deinitialized already from the while loop above.
        if (br_meta_idx > 0) {
            assert(offset > 0);
            self.meta.deleteOldest(br_meta_idx);
            self.data.deleteOldest(offset);
            @panic("TODO: TEST");
        }

        // Move our data one beyond so we don't rematch.
        self.data_offset = start - offset + 1;

        return Selection.init(tl, br, false);
    }

    /// Convert a data index into a pin.
    ///
    /// Tip: you can get the offset into the meta buffer we searched
    /// by inspecting the iterator index after this function returns.
    /// I note this because this is useful if you want to prune the
    /// meta buffer after you find a match.
    ///
    /// Precondition: the index must be within the data buffer.
    fn pin(
        it: *MetaBuf.Iterator,
        idx: usize,
    ) Pin {
        var offset: usize = 0;
        while (it.next()) |meta| {
            // meta_i is the index we expect to find the match in the
            // cell map within this meta if it contains it.
            const meta_i = idx - offset;
            if (meta_i >= meta.cell_map.items.len) {
                // This meta doesn't contain the match. This means we
                // can also prune this set of data because we only look
                // forward.
                offset += meta.cell_map.items.len;
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

    /// Add a new node to the sliding window.
    ///
    /// The window will prune itself if it can while always maintaining
    /// the invariant that the `fixed_size` always fits within the window.
    ///
    /// Note it is possible for the window to be smaller than `fixed_size`
    /// if not enough nodes have been added yet or the screen is just
    /// smaller than the needle.
    pub fn append(
        self: *SlidingWindow,
        alloc: Allocator,
        node: *PageList.List.Node,
        required_size: usize,
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

        // Now that we know our buffer length, we can consider if we can
        // prune our circular buffer or if we need to grow it.
        prune: {
            // Our buffer size after adding the new node.
            const before_size: usize = self.data.len() + encoded.items.len;

            // Prune as long as removing the first (oldest) node retains
            // our required size invariant.
            var after_size: usize = before_size;
            while (self.meta.first()) |oldest_meta| {
                const new_size = after_size - oldest_meta.cell_map.items.len;
                if (new_size < required_size) break :prune;

                // We can prune this node and retain our invariant.
                // Update our new size, deinitialize the memory, and
                // remove from the circular buffer.
                after_size = new_size;
                oldest_meta.deinit();
                self.meta.deleteOldest(1);
            }
            assert(after_size <= before_size);

            // If we didn't prune anything then we're done.
            if (after_size == before_size) break :prune;

            // We need to prune our data buffer as well.
            self.data.deleteOldest(before_size - after_size);
        }

        // Ensure our buffers are big enough to store what we need.
        try self.data.ensureUnusedCapacity(alloc, encoded.items.len);
        try self.meta.ensureUnusedCapacity(alloc, 1);

        // Append our new node to the circular buffer.
        try self.data.appendSlice(encoded.items);
        try self.meta.append(meta);

        // Integrity check: verify our data matches our metadata exactly.
        if (comptime std.debug.runtime_safety) {
            var meta_it = self.meta.iterator(.forward);
            var data_len: usize = 0;
            while (meta_it.next()) |m| data_len += m.cell_map.items.len;
            assert(data_len == self.data.len());
        }
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
    try w.append(alloc, node, needle.len);

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
    try w.append(alloc, node, needle.len);
    try w.append(alloc, node.next.?, needle.len);

    // Ensure our data is correct
}

pub const PageSearch = struct {
    alloc: Allocator,
    node: *PageList.List.Node,
    needle: []const u8,
    cell_map: Page.CellMap,
    encoded: std.ArrayListUnmanaged(u8) = .{},
    i: usize = 0,

    pub fn init(
        alloc: Allocator,
        node: *PageList.List.Node,
        needle: []const u8,
    ) !PageSearch {
        var result: PageSearch = .{
            .alloc = alloc,
            .node = node,
            .needle = needle,
            .cell_map = Page.CellMap.init(alloc),
        };

        const page: *const Page = &node.data;
        _ = try page.encodeUtf8(result.encoded.writer(alloc), .{
            .cell_map = &result.cell_map,
        });

        return result;
    }

    pub fn deinit(self: *PageSearch) void {
        self.encoded.deinit(self.alloc);
        self.cell_map.deinit();
    }

    pub fn next(self: *PageSearch) ?Selection {
        // Search our haystack for the needle. The resulting index is
        // the offset from self.i not the absolute index.
        const haystack: []const u8 = self.encoded.items[self.i..];
        const i_offset = std.mem.indexOf(u8, haystack, self.needle) orelse {
            self.i = self.encoded.items.len;
            return null;
        };

        // Get our full index into the encoded buffer.
        const idx = self.i + i_offset;

        // We found our search term. Move the cursor forward one beyond
        // the match. This lets us find every repeated match.
        self.i = idx + 1;

        const tl: PageList.Pin = tl: {
            const map = self.cell_map.items[idx];
            break :tl .{
                .node = self.node,
                .y = map.y,
                .x = map.x,
            };
        };
        const br: PageList.Pin = br: {
            const map = self.cell_map.items[idx + self.needle.len - 1];
            break :br .{
                .node = self.node,
                .y = map.y,
                .x = map.x,
            };
        };

        return Selection.init(tl, br, false);
    }
};

test "search single page one match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("hello, world");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;

    var it = try PageSearch.init(alloc, node, "world");
    defer it.deinit();

    const sel = it.next().?;
    try testing.expectEqual(point.Point{ .active = .{
        .x = 7,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start()).?);
    try testing.expectEqual(point.Point{ .active = .{
        .x = 11,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end()).?);

    try testing.expect(it.next() == null);
}

test "search single page multiple match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;

    var it = try PageSearch.init(alloc, node, "boo!");
    defer it.deinit();

    {
        const sel = it.next().?;
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
        const sel = it.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    try testing.expect(it.next() == null);
}
