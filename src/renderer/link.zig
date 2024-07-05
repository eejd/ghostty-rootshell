const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const configpkg = @import("../config.zig");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: oni.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }
};

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links = std.ArrayList(Link).init(alloc);
        defer links.deinit();

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(.{
                .regex = regex,
                .highlight = link.highlight,
            });
        }

        return .{ .links = try links.toOwnedSlice() };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Returns the matchset for the viewport state. The matchset is the
    /// full set of matching links for the visible viewport. A link
    /// only matches if it is also in the correct state (i.e. hovered
    /// if necessary).
    ///
    /// This is not a particularly efficient operation. This should be
    /// called sparingly.
    pub fn matchSet(
        self: *const Set,
        alloc: Allocator,
        screen: *Screen,
        mouse_vp_pt: point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !MatchSet {
        // Convert the viewport point to a screen point.
        const mouse_pin = screen.pages.pin(.{
            .viewport = mouse_vp_pt,
        }) orelse return .{};

        // This contains our list of matches. The matches are stored
        // as selections which contain the start and end points of
        // the match. There is no way to map these back to the link
        // configuration right now because we don't need to.
        var matches = std.ArrayList(terminal.Selection).init(alloc);
        defer matches.deinit();

        // If our mouse is over an OSC8 link, then we can skip the regex
        // matches below since OSC8 takes priority.
        try self.matchSetFromOSC8(
            alloc,
            &matches,
            screen,
            mouse_pin,
            mouse_mods,
        );

        // If we have no matches then we can try the regex matches.
        if (matches.items.len == 0) {
            try self.matchSetFromLinks(
                alloc,
                &matches,
                screen,
                mouse_pin,
                mouse_mods,
            );
        }

        return .{ .matches = try matches.toOwnedSlice() };
    }

    fn matchSetFromOSC8(
        self: *const Set,
        alloc: Allocator,
        matches: *std.ArrayList(terminal.Selection),
        screen: *Screen,
        mouse_pin: terminal.Pin,
        mouse_mods: inputpkg.Mods,
    ) !void {
        _ = alloc;
        _ = self;

        // If the right mods aren't pressed, then we can't match.
        if (!mouse_mods.equal(inputpkg.ctrlOrSuper(.{}))) return;

        // Check if the cell the mouse is over is an OSC8 hyperlink
        const mouse_cell = mouse_pin.rowAndCell().cell;
        if (!mouse_cell.hyperlink) return;

        // Get our hyperlink entry
        const page = &mouse_pin.page.data;
        const link_id = page.lookupHyperlink(mouse_cell) orelse {
            log.warn("failed to find hyperlink for cell", .{});
            return;
        };

        // Go through every row and find matching hyperlinks for the given ID.
        // Note the link ID is not the same as the OSC8 ID parameter. But
        // we hash hyperlinks by their contents which should achieve the same
        // thing so we can use the ID as a key.
        var current: ?terminal.Selection = null;
        var row_it = screen.pages.getTopLeft(.viewport).rowIterator(.right_down, null);
        while (row_it.next()) |row_pin| {
            const row = row_pin.rowAndCell().row;

            // If the row doesn't have any hyperlinks then we're done
            // building our matching selection.
            if (!row.hyperlink) {
                if (current) |sel| {
                    try matches.append(sel);
                    current = null;
                }

                continue;
            }

            // We have hyperlinks, look for our own matching hyperlink.
            for (row_pin.cells(.right), 0..) |*cell, x| {
                const match = match: {
                    if (cell.hyperlink) {
                        if (row_pin.page.data.lookupHyperlink(cell)) |cell_link_id| {
                            break :match cell_link_id == link_id;
                        }
                    }
                    break :match false;
                };

                // If we have a match, extend our selection or start a new
                // selection.
                if (match) {
                    const cell_pin = row_pin.right(x);
                    if (current) |*sel| {
                        sel.endPtr().* = cell_pin;
                    } else {
                        current = terminal.Selection.init(
                            cell_pin,
                            cell_pin,
                            false,
                        );
                    }

                    continue;
                }

                // No match, if we have a current selection then complete it.
                if (current) |sel| {
                    try matches.append(sel);
                    current = null;
                }
            }
        }
    }

    /// Fills matches with the matches from regex link matches.
    fn matchSetFromLinks(
        self: *const Set,
        alloc: Allocator,
        matches: *std.ArrayList(terminal.Selection),
        screen: *Screen,
        mouse_pin: terminal.Pin,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // Iterate over all the visible lines.
        var lineIter = screen.lineIterator(screen.pages.pin(.{
            .viewport = .{},
        }) orelse return);
        while (lineIter.next()) |line_sel| {
            const strmap: terminal.StringMap = strmap: {
                var strmap: terminal.StringMap = undefined;
                const str = screen.selectionString(alloc, .{
                    .sel = line_sel,
                    .trim = false,
                    .map = &strmap,
                }) catch |err| {
                    log.warn(
                        "failed to build string map for link checking err={}",
                        .{err},
                    );
                    continue;
                };
                alloc.free(str);
                break :strmap strmap;
            };
            defer strmap.deinit(alloc);

            // Go through each link and see if we have any matches.
            for (self.links) |link| {
                // Determine if our highlight conditions are met. We use a
                // switch here instead of an if so that we can get a compile
                // error if any other conditions are added.
                switch (link.highlight) {
                    .always => {},
                    .always_mods => |v| if (!mouse_mods.equal(v)) continue,
                    inline .hover, .hover_mods => |v, tag| {
                        if (!line_sel.contains(screen, mouse_pin)) continue;
                        if (comptime tag == .hover_mods) {
                            if (!mouse_mods.equal(v)) continue;
                        }
                    },
                }

                var it = strmap.searchIterator(link.regex);
                while (true) {
                    const match_ = it.next() catch |err| {
                        log.warn("failed to search for link err={}", .{err});
                        break;
                    };
                    var match = match_ orelse break;
                    defer match.deinit();
                    const sel = match.selection();

                    // If this is a highlight link then we only want to
                    // include matches that include our hover point.
                    switch (link.highlight) {
                        .always, .always_mods => {},
                        .hover,
                        .hover_mods,
                        => if (!sel.contains(screen, mouse_pin)) continue,
                    }

                    try matches.append(sel);
                }
            }
        }
    }
};

/// MatchSet is the result of matching links against a screen. This contains
/// all the matching links and operations on them such as whether a specific
/// cell is part of a matched link.
pub const MatchSet = struct {
    /// The matches.
    ///
    /// Important: this must be in left-to-right top-to-bottom order.
    matches: []const terminal.Selection = &.{},
    i: usize = 0,

    pub fn deinit(self: *MatchSet, alloc: Allocator) void {
        alloc.free(self.matches);
    }

    /// Checks if the matchset contains the given pin. This is slower than
    /// orderedContains but is stateless and more flexible since it doesn't
    /// require the points to be in order.
    pub fn contains(
        self: *MatchSet,
        screen: *const Screen,
        pin: terminal.Pin,
    ) bool {
        for (self.matches) |sel| {
            if (sel.contains(screen, pin)) return true;
        }

        return false;
    }

    /// Checks if the matchset contains the given pt. The points must be
    /// given in left-to-right top-to-bottom order. This is a stateful
    /// operation and giving a point out of order can cause invalid
    /// results.
    pub fn orderedContains(
        self: *MatchSet,
        screen: *const Screen,
        pin: terminal.Pin,
    ) bool {
        // If we're beyond the end of our possible matches, we're done.
        if (self.i >= self.matches.len) return false;

        // If our selection ends before the point, then no point will ever
        // again match this selection so we move on to the next one.
        while (self.matches[self.i].end().before(pin)) {
            self.i += 1;
            if (self.i >= self.matches.len) return false;
        }

        return self.matches[self.i].contains(screen, pin);
    }
};

test "matchset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our screen
    var s = try Screen.init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var match = try set.matchSet(alloc, &s, .{}, .{});
    defer match.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), match.matches.len);

    // Test our matches
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 0,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 2,
        .y = 0,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 3,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 1,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 2,
    } }).?));
}

test "matchset hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our screen
    var s = try Screen.init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var match = try set.matchSet(alloc, &s, .{}, .{});
        defer match.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), match.matches.len);

        // Test our matches
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 0,
            .y = 0,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 0,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 2,
            .y = 0,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 3,
            .y = 0,
        } }).?));
        try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 1,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 2,
        } }).?));
    }

    // Hovering over the first link
    {
        var match = try set.matchSet(alloc, &s, .{ .x = 1, .y = 0 }, .{});
        defer match.deinit(alloc);
        try testing.expectEqual(@as(usize, 2), match.matches.len);

        // Test our matches
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 0,
            .y = 0,
        } }).?));
        try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 0,
        } }).?));
        try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 2,
            .y = 0,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 3,
            .y = 0,
        } }).?));
        try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 1,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 2,
        } }).?));
    }
}

test "matchset mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our screen
    var s = try Screen.init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var match = try set.matchSet(alloc, &s, .{}, .{});
    defer match.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), match.matches.len);

    // Test our matches
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 0,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 2,
        .y = 0,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 3,
        .y = 0,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 1,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 2,
    } }).?));
}

test "matchset osc8" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our terminal
    var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    const s = &t.screen;

    try t.printString("ABC");
    try t.screen.startHyperlink("http://example.com", null);
    try t.printString("123");
    t.screen.endHyperlink();

    // Get a set
    var set = try Set.fromConfig(alloc, &.{});
    defer set.deinit(alloc);

    // No matches over the non-link
    {
        var match = try set.matchSet(
            alloc,
            &t.screen,
            .{ .x = 2, .y = 0 },
            inputpkg.ctrlOrSuper(.{}),
        );
        defer match.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), match.matches.len);
    }

    // Match over link
    var match = try set.matchSet(
        alloc,
        &t.screen,
        .{ .x = 3, .y = 0 },
        inputpkg.ctrlOrSuper(.{}),
    );
    defer match.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), match.matches.len);

    // Test our matches
    try testing.expect(!match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 2,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 3,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 4,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 5,
        .y = 0,
    } }).?));
    try testing.expect(!match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 6,
        .y = 0,
    } }).?));
}
