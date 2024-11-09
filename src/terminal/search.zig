const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const terminal = @import("main.zig");
const point = terminal.point;
const Page = terminal.Page;
const PageList = terminal.PageList;
const Selection = terminal.Selection;
const Screen = terminal.Screen;

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
