const std = @import("std");
const terminal = @import("main.zig");
const Screen = terminal.Screen;

// This file contains various types to represent x/y coordinates. We
// use different types so that we can lean on type-safety to get the
// exact expected type of point.

/// Viewport is a point within the viewport of the screen.
pub const Viewport = struct {
    x: usize = 0,
    y: usize = 0,

    pub fn toScreen(self: Viewport, screen: *const Screen) ScreenPoint {
        // x is unchanged, y we have to add the visible offset to
        // get the full offset from the top.
        return .{
            .x = self.x,
            .y = screen.visible_offset + self.y,
        };
    }

    test "toScreen with no scrollback" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var s = try Screen.init(alloc, 3, 5, 0);
        defer s.deinit(alloc);

        try testing.expectEqual(ScreenPoint{
            .x = 1,
            .y = 1,
        }, (Viewport{ .x = 1, .y = 1 }).toScreen(&s));
    }

    test "toScreen with scrollback" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var s = try Screen.init(alloc, 3, 5, 3);
        defer s.deinit(alloc);

        // At the bottom
        s.scroll(.{ .delta = 6 });
        try testing.expectEqual(ScreenPoint{
            .x = 0,
            .y = 3,
        }, (Viewport{ .x = 0, .y = 0 }).toScreen(&s));

        // Move the viewport a bit up
        s.scroll(.{ .delta = -1 });
        try testing.expectEqual(ScreenPoint{
            .x = 0,
            .y = 2,
        }, (Viewport{ .x = 0, .y = 0 }).toScreen(&s));

        // Move the viewport to top
        s.scroll(.{ .top = {} });
        try testing.expectEqual(ScreenPoint{
            .x = 0,
            .y = 0,
        }, (Viewport{ .x = 0, .y = 0 }).toScreen(&s));
    }
};

/// A screen point. This is offset from the top of the scrollback
/// buffer. If the screen is scrolled or resized, this will have to
/// be recomputed.
pub const ScreenPoint = struct {
    x: usize = 0,
    y: usize = 0,
};

test {
    std.testing.refAllDecls(@This());
}
