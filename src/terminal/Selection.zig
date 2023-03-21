/// Represents a single selection within the terminal
/// (i.e. a highlight region).
const Selection = @This();

const std = @import("std");
const point = @import("point.zig");
const Screen = @import("Screen.zig");
const ScreenPoint = point.ScreenPoint;

/// Start and end of the selection. There is no guarantee that
/// start is before end or vice versa. If a user selects backwards,
/// start will be after end, and vice versa. Use the struct functions
/// to not have to worry about this.
start: ScreenPoint,
end: ScreenPoint,

/// Converts a selection screen points to viewport points (still typed
/// as ScreenPoints) if the selection is present within the viewport
/// of the screen.
pub fn toViewport(self: Selection, screen: *const Screen) ?Selection {
    const top = (point.Viewport{ .x = 0, .y = 0 }).toScreen(screen);
    const bot = (point.Viewport{ .x = 0, .y = screen.rows - 1 }).toScreen(screen);

    // If our selection isn't within the viewport, do nothing.
    if (!self.within(top, bot)) return null;

    // Convert
    const start = self.start.toViewport(screen);
    const end = self.end.toViewport(screen);
    return Selection{
        .start = .{ .x = start.x, .y = start.y },
        .end = .{ .x = end.x, .y = end.y },
    };
}

/// Returns true if the selection is empty.
pub fn empty(self: Selection) bool {
    return self.start.x == self.end.x and self.start.y == self.end.y;
}

/// Returns true if the selection contains the given point.
///
/// This recalculates top left and bottom right each call. If you have
/// many points to check, it is cheaper to do the containment logic
/// yourself and cache the topleft/bottomright.
pub fn contains(self: Selection, p: ScreenPoint) bool {
    const tl = self.topLeft();
    const br = self.bottomRight();

    // Honestly there is probably way more efficient boolean logic here.
    // Look back at this in the future...

    // If tl/br are same line
    if (tl.y == br.y) return p.y == tl.y and
        p.x >= tl.x and
        p.x <= br.x;

    // If on top line, just has to be left of X
    if (p.y == tl.y) return p.x >= tl.x;

    // If on bottom line, just has to be right of X
    if (p.y == br.y) return p.x <= br.x;

    // If between the top/bottom, always good.
    return p.y > tl.y and p.y < br.y;
}

/// Returns true if the selection contains any of the points between
/// (and including) the start and end. The x values are ignored this is
/// just a section match
pub fn within(self: Selection, start: ScreenPoint, end: ScreenPoint) bool {
    const tl = self.topLeft();
    const br = self.bottomRight();
    return tl.y >= start.y and br.y <= end.y;
}

/// Returns true if the selection contains the row of the given point,
/// regardless of the x value.
pub fn containsRow(self: Selection, p: ScreenPoint) bool {
    const tl = self.topLeft();
    const br = self.bottomRight();
    return p.y >= tl.y and p.y <= br.y;
}

/// Returns the top left point of the selection.
pub fn topLeft(self: Selection) ScreenPoint {
    return switch (self.order()) {
        .forward => self.start,
        .reverse => self.end,
    };
}

/// Returns the bottom right point of the selection.
pub fn bottomRight(self: Selection) ScreenPoint {
    return switch (self.order()) {
        .forward => self.end,
        .reverse => self.start,
    };
}

/// The order of the selection (whether it is selecting forward or back).
const Order = enum { forward, reverse };

fn order(self: Selection) Order {
    if (self.start.y < self.end.y) return .forward;
    if (self.start.y > self.end.y) return .reverse;
    if (self.start.x <= self.end.x) return .forward;
    return .reverse;
}

test "Selection: contains" {
    const testing = std.testing;
    {
        const sel: Selection = .{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 2 },
        };

        try testing.expect(sel.contains(.{ .x = 6, .y = 1 }));
        try testing.expect(sel.contains(.{ .x = 1, .y = 2 }));
        try testing.expect(!sel.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 5, .y = 2 }));
        try testing.expect(!sel.containsRow(.{ .x = 1, .y = 3 }));
        try testing.expect(sel.containsRow(.{ .x = 1, .y = 1 }));
        try testing.expect(sel.containsRow(.{ .x = 5, .y = 2 }));
    }

    // Reverse
    {
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 2 },
            .end = .{ .x = 5, .y = 1 },
        };

        try testing.expect(sel.contains(.{ .x = 6, .y = 1 }));
        try testing.expect(sel.contains(.{ .x = 1, .y = 2 }));
        try testing.expect(!sel.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 5, .y = 2 }));
    }

    // Single line
    {
        const sel: Selection = .{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 10, .y = 1 },
        };

        try testing.expect(sel.contains(.{ .x = 6, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 2, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 12, .y = 1 }));
    }
}

test "Selection: within" {
    const testing = std.testing;
    {
        const sel: Selection = .{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 2 },
        };

        try testing.expect(sel.within(.{ .x = 6, .y = 0 }, .{ .x = 6, .y = 3 }));
        try testing.expect(sel.within(.{ .x = 3, .y = 1 }, .{ .x = 6, .y = 3 }));
        try testing.expect(sel.within(.{ .x = 3, .y = 0 }, .{ .x = 6, .y = 2 }));
    }
}
