const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const CircBuf = @import("../datastruct/main.zig").CircBuf;
const terminal = @import("main.zig");
const point = terminal.point;
const Page = terminal.Page;
const PageList = terminal.PageList;
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
