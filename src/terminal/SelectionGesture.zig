/// SelectionGesture manages gesture-based selection logic (mouse press, drag,
/// etc.). Callers setup initial state, make calls for various external
/// events, and react to the requested effects.
const SelectionGesture = @This();

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Selection = @import("Selection.zig");
const Terminal = @import("Terminal.zig");

/// The tracked pin of the initial left click along with the screen
/// that the pin is part of.
left_click_pin: ?*Pin,
left_click_screen: ScreenSet.Key,
left_click_screen_generation: usize,

/// The count of clicks to count double and triple clicks and so on.
/// The left click time was the last time the left click was done, if the
/// caller could provide one. If this is null then we only support single clicks.
left_click_count: u3,
left_click_time: ?std.time.Instant,

/// The starting xpos/ypos of the left click. Note that if scrolling occurs,
/// these will point to different cells, but the xpos/ypos will stay
/// stable during scrolling relative to the surface.
left_click_xpos: f64,
left_click_ypos: f64,

/// True once the active left-click gesture has moved away from the initially
/// pressed cell. This is reset on every press that starts or continues a
/// multi-click sequence, and is left available for callers to inspect while
/// handling the corresponding release.
left_click_dragged: bool,

/// The current autoscroll state for the active left-click drag gesture.
left_drag_autoscroll: Autoscroll,

/// The direction that selection dragging should autoscroll the viewport.
/// This is derived from the most recent drag position relative to the
/// surface bounds and reset whenever there is no active drag gesture.
///
/// When autoscroll is non-none, the caller should setup a timer
/// to periodically call autoscrollTick. The timer interval is up to the
/// caller but reasonable defaults are approximately every 15 milliseconds.
///
/// This is used to implement selection above/below the viewport that
/// wants to drag the viewport.
pub const Autoscroll = enum { none, up, down };

/// Distance from the top or bottom surface edge, in pixels, where dragging
/// should request autoscroll. This preserves the historical 1px buffer used
/// so fullscreen-edge drags can still trigger autoscroll.
const autoscroll_buffer: f64 = 1;

pub const init: SelectionGesture = .{
    .left_click_pin = null,
    .left_click_count = 0,
    .left_click_time = null,
    .left_click_screen = .primary,
    .left_click_screen_generation = 0,
    .left_click_xpos = 0,
    .left_click_ypos = 0,
    .left_click_dragged = false,
    .left_drag_autoscroll = .none,
};

pub fn deinit(self: *SelectionGesture, t: *Terminal) void {
    // Grab our pagelist that is associated with the pin. If it doesn't
    // exist anymore then our tracked pin is already free.
    const pin = self.left_click_pin orelse return;
    if (t.screens.generation(self.left_click_screen) != self.left_click_screen_generation) return;
    const screen = t.screens.get(self.left_click_screen) orelse return;
    screen.pages.untrackPin(pin);
}

/// Reset any active gesture state and untrack the tracked click pin.
pub fn reset(self: *SelectionGesture, t: *Terminal) void {
    self.left_click_count = 0;
    self.left_click_time = null;
    self.left_click_dragged = false;
    self.left_drag_autoscroll = .none;
    self.untrackPin(t);
}

/// Return the tracked left-click pin only if it still belongs to the active
/// screen instance. This validates both the screen key and generation so a pin
/// from a removed, recycled, or inactive screen is never exposed to callers.
pub fn validatedLeftClickPin(
    self: *const SelectionGesture,
    screens: *const ScreenSet,
) ?*Pin {
    const pin = self.left_click_pin orelse return null;
    if (self.left_click_screen != screens.active_key) return null;
    if (screens.generation(self.left_click_screen) != self.left_click_screen_generation) return null;
    _ = screens.get(self.left_click_screen) orelse return null;
    return pin;
}

pub const Press = struct {
    /// The time when the press event occurred. Use a monotonic timer.
    /// This can be null if you're on a system that doesn't support
    /// time for some reason. In that case, we only support single clicks.
    time: ?std.time.Instant,

    /// The cell where the click was.
    pin: Pin,

    /// The x/y value of the click relative to the surface with (0,0) being
    /// top-left. This is used for distance detection for multi-clicks so
    /// double/triple clicks too far away from each other will reset the click
    /// count as well more accurate drag behaviors.
    xpos: f64,
    ypos: f64,

    /// Maximum distance a click can be from the original click to register
    /// as a repeat. If uncertain, set this to cell width.
    max_distance: f64,

    /// The maximum interval in nanoseconds that a press is considered
    /// a repeat e.g. to record double/triple clicks.
    repeat_interval: u64,
};

/// Record a press event.
pub fn press(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) Allocator.Error!void {
    if (self.left_click_count > 0) {
        if (self.pressRepeat(t, p)) {
            // Successful repeat, return.
            return;
        } else |err| switch (err) {
            error.PressRequiresReset => {},
        }
    }

    // Initial click or the repeat failed for some reason such as
    // the subsequent click being too far away.
    try self.pressInitial(t, p);
}

pub const Drag = struct {
    /// The cell where the current drag position is. This is used
    /// synchronously to calculate the selection and is not tracked.
    pin: Pin,

    /// The x/y value of the drag relative to the surface with (0,0) being
    /// top-left.
    xpos: f64,
    ypos: f64,

    /// True if the current drag should produce a rectangular selection.
    rectangle: bool,

    /// The codepoints that delimit words for double-click drag selection.
    word_boundary_codepoints: []const u21,

    /// Geometry required for selection threshold and autoscroll calculations.
    geometry: Geometry,

    /// Display geometry needed to translate surface-relative pointer positions
    /// into selection behavior.
    pub const Geometry = struct {
        /// The number of columns in the rendered terminal grid.
        columns: u32,

        /// The width of one terminal cell in surface pixels.
        cell_width: u32,

        /// The left padding before the terminal grid begins, in surface pixels.
        padding_left: u32,

        /// The height of the rendered terminal surface in surface pixels.
        screen_height: u32,
    };
};

/// Record a drag event and return the current untracked drag selection.
pub fn drag(
    self: *SelectionGesture,
    t: *Terminal,
    d: Drag,
) ?Selection {
    // If we aren't currently clicked then we don't do any dragging
    // behavior.
    if (self.left_click_count == 0) {
        assert(self.left_drag_autoscroll == .none);
        return null;
    }

    // Get our click pin. We get a validated pin because if our
    // screen changed out from under us then we aren't actually
    // clicking anymore.
    const click_pin = self.validatedLeftClickPin(&t.screens) orelse return null;
    if (!d.pin.eql(click_pin.*)) self.left_click_dragged = true;

    // Determine if we should autoscroll. If our drag position is above
    // the top, we go up. If its below the bottom we go down. Easy.
    const max_y: f64 = @floatFromInt(d.geometry.screen_height);
    self.left_drag_autoscroll = if (d.ypos <= autoscroll_buffer)
        .up
    else if (d.ypos > max_y - autoscroll_buffer)
        .down
    else
        .none;

    return switch (self.left_click_count) {
        0 => unreachable, // handled above

        1 => dragSelection(
            click_pin.*,
            d.pin,
            @intFromFloat(@max(0, self.left_click_xpos)),
            @intFromFloat(@max(0, d.xpos)),
            d.rectangle,
            d.geometry,
        ),

        2 => dragSelectionWord(
            t.screens.active,
            click_pin.*,
            d.pin,
            d.word_boundary_codepoints,
        ),

        3 => dragSelectionLine(
            t.screens.active,
            click_pin.*,
            d.pin,
        ),
        else => unreachable,
    };
}

/// Record a selection autoscroll tick for the active left-click drag gesture.
/// This scrolls the viewport in the active autoscroll direction and then
/// continues the drag at the provided position.
pub fn autoscrollTick(
    self: *SelectionGesture,
    t: *Terminal,
    d: Drag,
) ?Selection {
    if (self.left_click_count == 0) {
        assert(self.left_drag_autoscroll == .none);
        return null;
    }

    const delta: isize = switch (self.left_drag_autoscroll) {
        .none => return null,
        .up => -1,
        .down => 1,
    };

    // If our click pin no longer belongs to the active screen, the gesture is
    // no longer valid. Stop it so callers can stop their autoscroll timer
    // without clearing the current selection as if this were a real drag.
    _ = self.validatedLeftClickPin(&t.screens) orelse {
        self.reset(t);
        return null;
    };

    t.scrollViewport(.{ .delta = delta });
    return self.drag(t, d);
}

pub const Release = struct {
    /// The cell where the release occurred, if the release position mapped to
    /// a valid cell. This is used synchronously to update gesture state and is
    /// not tracked.
    pin: ?Pin,
};

/// Record a release event for the active left-click gesture.
pub fn release(
    self: *SelectionGesture,
    t: *Terminal,
    r: Release,
) void {
    if (self.left_click_count == 0) {
        assert(self.left_drag_autoscroll == .none);
        return;
    }

    if (r.pin) |release_pin| {
        if (self.validatedLeftClickPin(&t.screens)) |click_pin| {
            if (!release_pin.eql(click_pin.*)) self.left_click_dragged = true;
        }
    } else {
        self.left_click_dragged = true;
    }
    self.left_drag_autoscroll = .none;
}

fn pressInitial(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) Allocator.Error!void {
    // Setup our pin first, reusing our existing pin if we can.
    if (self.left_click_pin) |pin| {
        if (comptime std.debug.runtime_safety) {
            assert(self.left_click_screen == t.screens.active_key);
            assert(self.left_click_screen_generation == t.screens.generation(t.screens.active_key));
        }
        pin.* = p.pin;
    } else {
        const screens: *const ScreenSet = &t.screens;
        self.left_click_pin = try screens.active.pages.trackPin(p.pin);
        errdefer comptime unreachable;
        self.left_click_screen = screens.active_key;
        self.left_click_screen_generation = screens.generation(screens.active_key);
    }
    errdefer comptime unreachable;
    self.left_click_count = 1;
    self.left_click_xpos = p.xpos;
    self.left_click_ypos = p.ypos;
    self.left_click_time = p.time;
    self.left_click_dragged = false;
    self.left_drag_autoscroll = .none;
}

fn pressRepeat(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) error{PressRequiresReset}!void {
    errdefer {
        self.left_click_count = 0;
        self.untrackPin(t);
    }

    // If too much time has passed then we always reset.
    const time = p.time orelse return error.PressRequiresReset;
    {
        const prev_time = self.left_click_time orelse return error.PressRequiresReset;
        const since = time.since(prev_time);
        if (since > p.repeat_interval) return error.PressRequiresReset;
    }

    // If the click is too far away from the initial click we can't continue.
    const distance = @sqrt(
        std.math.pow(f64, p.xpos - self.left_click_xpos, 2) +
            std.math.pow(f64, p.ypos - self.left_click_ypos, 2),
    );
    if (distance > p.max_distance) return error.PressRequiresReset;

    // If our prior click was on another screen then free and reset. "Another screen"
    // doesn't just mean alt vs primary, it could mean an alt screen that was
    // recycled since we free tracked pins on recycle.
    const screens: *const ScreenSet = &t.screens;
    if (self.left_click_screen != screens.active_key or
        screens.generation(self.left_click_screen) !=
            self.left_click_screen_generation)
    {
        // The error return will trigger the top-level errdefer which
        // will reset our pin.
        return error.PressRequiresReset;
    }

    self.left_click_time = time;
    self.left_click_dragged = false;
    self.left_drag_autoscroll = .none;
    self.left_click_count = @min(
        self.left_click_count + 1,
        3, // We only support triple clicks max
    );
}

/// Calculates the appropriate selection given pins and pixel x positions for
/// the click point and the drag point, as well as selection mode and geometry.
fn dragSelection(
    click_pin: Pin,
    drag_pin: Pin,
    click_x: u32,
    drag_x: u32,
    rectangle_selection: bool,
    geometry: Drag.Geometry,
) ?Selection {
    // Explanation:
    //
    // # Normal selections
    //
    // ## Left-to-right selections
    // - The clicked cell is included if it was clicked to the left of its
    //   threshold point and the drag location is right of the threshold point.
    // - The cell under the cursor (the "drag cell") is included if the drag
    //   location is right of its threshold point.
    //
    // ## Right-to-left selections
    // - The clicked cell is included if it was clicked to the right of its
    //   threshold point and the drag location is left of the threshold point.
    // - The cell under the cursor (the "drag cell") is included if the drag
    //   location is left of its threshold point.
    //
    // # Rectangular selections
    //
    // Rectangular selections are handled similarly, except that
    // entire columns are considered rather than individual cells.

    // We only include cells in the selection if the threshold point lies
    // between the start and end points of the selection. A threshold of
    // 60% of the cell width was chosen empirically because it felt good.
    const threshold_point: u32 = @intFromFloat(@round(
        @as(f64, @floatFromInt(geometry.cell_width)) * 0.6,
    ));

    // We use this to clamp the pixel positions below.
    const max_x = geometry.columns * geometry.cell_width - 1;

    // We need to know how far across in the cell the drag pos is, so
    // we subtract the padding and then take it modulo the cell width.
    const drag_x_frac = @min(max_x, drag_x -| geometry.padding_left) % geometry.cell_width;

    // We figure out the fractional part of the click x position similarly.
    const click_x_frac = @min(max_x, click_x -| geometry.padding_left) % geometry.cell_width;

    // Whether the click pin and drag pin are equal.
    const same_pin = drag_pin.eql(click_pin);

    // Whether or not the end point of our selection is before the start point.
    const end_before_start = ebs: {
        if (same_pin) {
            break :ebs drag_x_frac < click_x_frac;
        }

        // Special handling for rectangular selections, we only use x position.
        if (rectangle_selection) {
            break :ebs switch (std.math.order(drag_pin.x, click_pin.x)) {
                .eq => drag_x_frac < click_x_frac,
                .lt => true,
                .gt => false,
            };
        }

        break :ebs drag_pin.before(click_pin);
    };

    // Whether or not the click pin cell
    // should be included in the selection.
    const include_click_cell = if (end_before_start)
        click_x_frac >= threshold_point
    else
        click_x_frac < threshold_point;

    // Whether or not the drag pin cell
    // should be included in the selection.
    const include_drag_cell = if (end_before_start)
        drag_x_frac < threshold_point
    else
        drag_x_frac >= threshold_point;

    // If the click cell should be included in the selection then it's the
    // start, otherwise we get the previous or next cell to it depending on
    // the type and direction of the selection.
    const start_pin =
        if (include_click_cell)
            click_pin
        else if (end_before_start)
            if (rectangle_selection)
                click_pin.leftClamp(1)
            else
                click_pin.leftWrap(1) orelse click_pin
        else if (rectangle_selection)
            click_pin.rightClamp(1)
        else
            click_pin.rightWrap(1) orelse click_pin;

    // Likewise for the end pin with the drag cell.
    const end_pin =
        if (include_drag_cell)
            drag_pin
        else if (end_before_start)
            if (rectangle_selection)
                drag_pin.rightClamp(1)
            else
                drag_pin.rightWrap(1) orelse drag_pin
        else if (rectangle_selection)
            drag_pin.leftClamp(1)
        else
            drag_pin.leftWrap(1) orelse drag_pin;

    // If the click cell is the same as the drag cell and the click cell
    // shouldn't be included, or if the cells are adjacent such that the
    // start or end pin becomes the other cell, and that cell should not
    // be included, then we have no selection, so we set it to null.
    //
    // If in rectangular selection mode, we compare columns as well.
    //
    // TODO(qwerasd): this can/should probably be refactored, it's a bit
    //                repetitive and does excess work in rectangle mode.
    if ((!include_click_cell and same_pin) or
        (!include_click_cell and rectangle_selection and click_pin.x == drag_pin.x) or
        (!include_click_cell and end_pin.eql(click_pin)) or
        (!include_click_cell and rectangle_selection and end_pin.x == click_pin.x) or
        (!include_drag_cell and start_pin.eql(drag_pin)) or
        (!include_drag_cell and rectangle_selection and start_pin.x == drag_pin.x))
    {
        return null;
    }

    // TODO: Clamp selection to the screen area, don't
    //       let it extend past the last written row.

    return .init(
        start_pin,
        end_pin,
        rectangle_selection,
    );
}

/// Calculates the appropriate word-wise selection for a double-click drag.
fn dragSelectionWord(
    screen: *Screen,
    click_pin: Pin,
    drag_pin: Pin,
    boundary_codepoints: []const u21,
) ?Selection {
    // Get the word closest to our starting click.
    const word_start = screen.selectWordBetween(
        click_pin,
        drag_pin,
        boundary_codepoints,
    ) orelse return null;

    // Get the word closest to our current point.
    const word_current = screen.selectWordBetween(
        drag_pin,
        click_pin,
        boundary_codepoints,
    ) orelse return null;

    // If our current mouse position is before the starting position,
    // then the selection start is the word nearest our current position.
    return if (drag_pin.before(click_pin))
        .init(
            word_current.start(),
            word_start.end(),
            false,
        )
    else
        .init(
            word_start.start(),
            word_current.end(),
            false,
        );
}

/// Calculates the appropriate line-wise selection for a triple-click drag.
fn dragSelectionLine(
    screen: *Screen,
    click_pin: Pin,
    drag_pin: Pin,
) ?Selection {
    // Get the line selection under our current drag point. If there isn't a
    // line, do nothing.
    const line = screen.selectLine(.{ .pin = drag_pin }) orelse return null;

    // Get the selection under our click point. We first try to trim
    // whitespace if we've selected a word. But if no word exists then
    // we select the blank line.
    const sel_ = screen.selectLine(.{ .pin = click_pin }) orelse
        screen.selectLine(.{ .pin = click_pin, .whitespace = null });

    var sel = sel_ orelse return null;
    if (drag_pin.before(click_pin)) {
        sel.startPtr().* = line.start();
    } else {
        sel.endPtr().* = line.end();
    }
    return sel;
}

fn untrackPin(self: *SelectionGesture, t: *Terminal) void {
    // Can't untrack unless we have a pin.
    const pin = self.left_click_pin orelse return;
    self.left_click_pin = null;

    // If the generation changed our pin is already invalid.
    const screens: *const ScreenSet = &t.screens;
    if (screens.generation(self.left_click_screen) != self.left_click_screen_generation) return;

    // If we can't get a screen then its already freed.
    const screen = screens.get(self.left_click_screen) orelse return;
    screen.pages.untrackPin(pin);
}

fn testPress(t: *Terminal, x: u16, y: u32, time: ?std.time.Instant) Press {
    return .{
        .time = time,
        .pin = t.screens.active.pages.pin(.{ .active = .{
            .x = x,
            .y = y,
        } }).?,
        .xpos = @floatFromInt(x),
        .ypos = @floatFromInt(y),
        .max_distance = 1,
        .repeat_interval = std.math.maxInt(u64),
    };
}

fn testDrag(t: *Terminal, x: u16, y: u32, xpos: f64, ypos: f64) Drag {
    return .{
        .pin = t.screens.active.pages.pin(.{ .active = .{
            .x = x,
            .y = y,
        } }).?,
        .xpos = xpos,
        .ypos = ypos,
        .rectangle = false,
        .word_boundary_codepoints = &.{},
        .geometry = .{
            .columns = 5,
            .cell_width = 10,
            .padding_left = 0,
            .screen_height = 100,
        },
    };
}

fn testPin(t: *Terminal, x: u16, y: u32) Pin {
    return t.screens.active.pages.pin(.{ .active = .{
        .x = x,
        .y = y,
    } }).?;
}

/// Utility function for the unit tests for drag selection logic.
///
/// Tests a click and drag on a 10x5 cell grid, x positions are given in
/// fractional cells, e.g. 3.1 would be 10% through the cell at x = 3.
///
/// NOTE: The geometry tested with has 10px wide cells, meaning only one digit
///       after the decimal place has any meaning, e.g. 3.14 is equal to 3.1.
///
/// The provided start_x/y and end_x/y are the expected start and end points
/// of the resulting selection.
fn testDragSelection(
    click_x: f64,
    click_y: u32,
    drag_x: f64,
    drag_y: u32,
    start_x: u16,
    start_y: u32,
    end_x: u16,
    end_y: u32,
    rect: bool,
) !void {
    assert(@import("builtin").is_test);

    // Our screen size is 10x5 cells that are
    // 10x20 px, with 5px padding on all sides.
    const geometry: Drag.Geometry = .{
        .columns = 10,
        .cell_width = 10,
        .padding_left = 5,
        .screen_height = 110,
    };
    var screen = try Screen.init(testing.allocator, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer screen.deinit();

    const click_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(click_x)), .y = click_y },
    }) orelse unreachable;
    const drag_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(drag_x)), .y = drag_y },
    }) orelse unreachable;

    const cell_width_f64: f64 = @floatFromInt(geometry.cell_width);
    const click_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(click_x * cell_width_f64))) +
        geometry.padding_left;
    const drag_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(drag_x * cell_width_f64))) +
        geometry.padding_left;

    const start_pin = screen.pages.pin(.{
        .viewport = .{ .x = start_x, .y = start_y },
    }) orelse unreachable;
    const end_pin = screen.pages.pin(.{
        .viewport = .{ .x = end_x, .y = end_y },
    }) orelse unreachable;

    try testing.expectEqualDeep(Selection{
        .bounds = .{ .untracked = .{
            .start = start_pin,
            .end = end_pin,
        } },
        .rectangle = rect,
    }, dragSelection(
        click_pin,
        drag_pin,
        click_x_pos,
        drag_x_pos,
        rect,
        geometry,
    ));
}

/// Like `testDragSelection` but checks that the resulting selection is null.
///
/// See `testDragSelection` for more details.
fn testDragSelectionIsNull(
    click_x: f64,
    click_y: u32,
    drag_x: f64,
    drag_y: u32,
    rect: bool,
) !void {
    assert(@import("builtin").is_test);

    // Our screen size is 10x5 cells that are
    // 10x20 px, with 5px padding on all sides.
    const geometry: Drag.Geometry = .{
        .columns = 10,
        .cell_width = 10,
        .padding_left = 5,
        .screen_height = 110,
    };
    var screen = try Screen.init(testing.allocator, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer screen.deinit();

    const click_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(click_x)), .y = click_y },
    }) orelse unreachable;
    const drag_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(drag_x)), .y = drag_y },
    }) orelse unreachable;

    const cell_width_f64: f64 = @floatFromInt(geometry.cell_width);
    const click_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(click_x * cell_width_f64))) +
        geometry.padding_left;
    const drag_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(drag_x * cell_width_f64))) +
        geometry.padding_left;

    try testing.expectEqual(
        null,
        dragSelection(
            click_pin,
            drag_pin,
            click_x_pos,
            drag_x_pos,
            rect,
            geometry,
        ),
    );
}

test "SelectionGesture drag selection logic" {
    // We disable format to make these easier to
    // read by pairing sets of coordinates per line.
    // zig fmt: off

    // -- LTR
    // single cell selection
    try testDragSelection(
        3.0, 3, // click
        3.9, 3, // drag
        3, 3, // expected start
        3, 3, // expected end
        false, // regular selection
    );
    // including click and drag pin cells
    try testDragSelection(
        3.0, 3, // click
        5.9, 3, // drag
        3, 3, // expected start
        5, 3, // expected end
        false, // regular selection
    );
    // including click pin cell but not drag pin cell
    try testDragSelection(
        3.0, 3, // click
        5.0, 3, // drag
        3, 3, // expected start
        4, 3, // expected end
        false, // regular selection
    );
    // including drag pin cell but not click pin cell
    try testDragSelection(
        3.9, 3, // click
        5.9, 3, // drag
        4, 3, // expected start
        5, 3, // expected end
        false, // regular selection
    );
    // including neither click nor drag pin cells
    try testDragSelection(
        3.9, 3, // click
        5.0, 3, // drag
        4, 3, // expected start
        4, 3, // expected end
        false, // regular selection
    );
    // empty selection (single cell on only left half)
    try testDragSelectionIsNull(
        3.0, 3, // click
        3.1, 3, // drag
        false, // regular selection
    );
    // empty selection (single cell on only right half)
    try testDragSelectionIsNull(
        3.8, 3, // click
        3.9, 3, // drag
        false, // regular selection
    );
    // empty selection (between two cells, not crossing threshold)
    try testDragSelectionIsNull(
        3.9, 3, // click
        4.0, 3, // drag
        false, // regular selection
    );

    // -- RTL
    // single cell selection
    try testDragSelection(
        3.9, 3, // click
        3.0, 3, // drag
        3, 3, // expected start
        3, 3, // expected end
        false, // regular selection
    );
    // including click and drag pin cells
    try testDragSelection(
        5.9, 3, // click
        3.0, 3, // drag
        5, 3, // expected start
        3, 3, // expected end
        false, // regular selection
    );
    // including click pin cell but not drag pin cell
    try testDragSelection(
        5.9, 3, // click
        3.9, 3, // drag
        5, 3, // expected start
        4, 3, // expected end
        false, // regular selection
    );
    // including drag pin cell but not click pin cell
    try testDragSelection(
        5.0, 3, // click
        3.0, 3, // drag
        4, 3, // expected start
        3, 3, // expected end
        false, // regular selection
    );
    // including neither click nor drag pin cells
    try testDragSelection(
        5.0, 3, // click
        3.9, 3, // drag
        4, 3, // expected start
        4, 3, // expected end
        false, // regular selection
    );
    // empty selection (single cell on only left half)
    try testDragSelectionIsNull(
        3.1, 3, // click
        3.0, 3, // drag
        false, // regular selection
    );
    // empty selection (single cell on only right half)
    try testDragSelectionIsNull(
        3.9, 3, // click
        3.8, 3, // drag
        false, // regular selection
    );
    // empty selection (between two cells, not crossing threshold)
    try testDragSelectionIsNull(
        4.0, 3, // click
        3.9, 3, // drag
        false, // regular selection
    );

    // -- Wrapping
    // LTR, wrap excluded cells
    try testDragSelection(
        9.9, 2, // click
        0.0, 4, // drag
        0, 3, // expected start
        9, 3, // expected end
        false, // regular selection
    );
    // RTL, wrap excluded cells
    try testDragSelection(
        0.0, 4, // click
        9.9, 2, // drag
        9, 3, // expected start
        0, 3, // expected end
        false, // regular selection
    );
}

test "SelectionGesture rectangle drag selection logic" {
    // We disable format to make these easier to
    // read by pairing sets of coordinates per line.
    // zig fmt: off

    // -- LTR
    // single column selection
    try testDragSelection(
        3.0, 2, // click
        3.9, 4, // drag
        3, 2, // expected start
        3, 4, // expected end
        true, //rectangle selection
    );
    // including click and drag pin columns
    try testDragSelection(
        3.0, 2, // click
        5.9, 4, // drag
        3, 2, // expected start
        5, 4, // expected end
        true, //rectangle selection
    );
    // including click pin column but not drag pin column
    try testDragSelection(
        3.0, 2, // click
        5.0, 4, // drag
        3, 2, // expected start
        4, 4, // expected end
        true, //rectangle selection
    );
    // including drag pin column but not click pin column
    try testDragSelection(
        3.9, 2, // click
        5.9, 4, // drag
        4, 2, // expected start
        5, 4, // expected end
        true, //rectangle selection
    );
    // including neither click nor drag pin columns
    try testDragSelection(
        3.9, 2, // click
        5.0, 4, // drag
        4, 2, // expected start
        4, 4, // expected end
        true, //rectangle selection
    );
    // empty selection (single column on only left half)
    try testDragSelectionIsNull(
        3.0, 2, // click
        3.1, 4, // drag
        true, //rectangle selection
    );
    // empty selection (single column on only right half)
    try testDragSelectionIsNull(
        3.8, 2, // click
        3.9, 4, // drag
        true, //rectangle selection
    );
    // empty selection (between two columns, not crossing threshold)
    try testDragSelectionIsNull(
        3.9, 2, // click
        4.0, 4, // drag
        true, //rectangle selection
    );

    // -- RTL
    // single column selection
    try testDragSelection(
        3.9, 2, // click
        3.0, 4, // drag
        3, 2, // expected start
        3, 4, // expected end
        true, //rectangle selection
    );
    // including click and drag pin columns
    try testDragSelection(
        5.9, 2, // click
        3.0, 4, // drag
        5, 2, // expected start
        3, 4, // expected end
        true, //rectangle selection
    );
    // including click pin column but not drag pin column
    try testDragSelection(
        5.9, 2, // click
        3.9, 4, // drag
        5, 2, // expected start
        4, 4, // expected end
        true, //rectangle selection
    );
    // including drag pin column but not click pin column
    try testDragSelection(
        5.0, 2, // click
        3.0, 4, // drag
        4, 2, // expected start
        3, 4, // expected end
        true, //rectangle selection
    );
    // including neither click nor drag pin columns
    try testDragSelection(
        5.0, 2, // click
        3.9, 4, // drag
        4, 2, // expected start
        4, 4, // expected end
        true, //rectangle selection
    );
    // empty selection (single column on only left half)
    try testDragSelectionIsNull(
        3.1, 2, // click
        3.0, 4, // drag
        true, //rectangle selection
    );
    // empty selection (single column on only right half)
    try testDragSelectionIsNull(
        3.9, 2, // click
        3.8, 4, // drag
        true, //rectangle selection
    );
    // empty selection (between two columns, not crossing threshold)
    try testDragSelectionIsNull(
        4.0, 2, // click
        3.9, 4, // drag
        true, //rectangle selection
    );

    // -- Wrapping
    // LTR, do not wrap
    try testDragSelection(
        9.9, 2, // click
        0.0, 4, // drag
        9, 2, // expected start
        0, 4, // expected end
        true, //rectangle selection
    );
    // RTL, do not wrap
    try testDragSelection(
        0.0, 4, // click
        9.9, 2, // drag
        0, 4, // expected start
        9, 2, // expected end
        true, //rectangle selection
    );
}

test "SelectionGesture press records initial click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 2, time));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(time, gesture.left_click_time.?);
    try testing.expectEqual(@as(f64, 1), gesture.left_click_xpos);
    try testing.expectEqual(@as(f64, 2), gesture.left_click_ypos);
    try testing.expectEqual(false, gesture.left_click_dragged);
}

test "SelectionGesture drag returns selection and records autoscroll" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    var press_event = testPress(&t, 1, 1, try std.time.Instant.now());
    press_event.xpos = 10;
    try gesture.press(&t, press_event);

    const sel = gesture.drag(&t, testDrag(&t, 3, 1, 39, 50)).?;
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    try testing.expectEqual(true, gesture.left_click_dragged);

    try testing.expectEqualDeep(Selection.init(
        t.screens.active.pages.pin(.{ .active = .{ .x = 1, .y = 1 } }).?,
        t.screens.active.pages.pin(.{ .active = .{ .x = 3, .y = 1 } }).?,
        false,
    ), sel);

    _ = gesture.drag(&t, testDrag(&t, 3, 1, 39, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);

    _ = gesture.drag(&t, testDrag(&t, 3, 1, 39, 100));
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);
}

test "SelectionGesture release clears autoscroll and records drag" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));
    try testing.expectEqual(false, gesture.left_click_dragged);

    _ = gesture.drag(&t, testDrag(&t, 1, 1, 10, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
    try testing.expectEqual(false, gesture.left_click_dragged);

    gesture.release(&t, .{
        .pin = testPin(&t, 2, 1),
    });
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    try testing.expectEqual(true, gesture.left_click_dragged);
}

test "SelectionGesture drag without press returns null" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    try testing.expectEqual(null, gesture.drag(&t, testDrag(&t, 1, 1, 10, 50)));
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
}

test "SelectionGesture drag autoscroll edge boundaries" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    var press_event = testPress(&t, 1, 1, try std.time.Instant.now());
    press_event.xpos = 10;
    try gesture.press(&t, press_event);

    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);

    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 1.1));
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);

    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 99));
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);

    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 99.1));
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);
}

test "SelectionGesture autoscroll tick scrolls and continues drag" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    var press_event = testPress(&t, 1, 1, try std.time.Instant.now());
    press_event.xpos = 10;
    try gesture.press(&t, press_event);

    _ = gesture.drag(&t, testDrag(&t, 3, 1, 39, 100));
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);

    const sel = gesture.autoscrollTick(&t, testDrag(&t, 3, 2, 39, 100)).?;
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);
    try testing.expectEqual(true, gesture.left_click_dragged);
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 1, 1),
        testPin(&t, 3, 2),
        false,
    ), sel);
}

test "SelectionGesture autoscroll tick stops with invalidated click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    var press_event = testPress(&t, 1, 1, try std.time.Instant.now());
    press_event.xpos = 10;
    try gesture.press(&t, press_event);

    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);

    _ = try t.screens.getInit(testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);

    try testing.expectEqual(null, gesture.autoscrollTick(&t, testDrag(&t, 2, 1, 20, 1)));
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    try testing.expectEqual(@as(u3, 0), gesture.left_click_count);
}

test "SelectionGesture drag with invalidated click returns null" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    var press_event = testPress(&t, 1, 1, try std.time.Instant.now());
    press_event.xpos = 10;
    try gesture.press(&t, press_event);

    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);

    _ = try t.screens.getInit(testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);

    try testing.expectEqual(null, gesture.drag(&t, testDrag(&t, 2, 1, 20, 50)));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
}

test "SelectionGesture double-click drag selects by word" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta gamma");

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 0, time));
    try gesture.press(&t, testPress(&t, 1, 0, time));

    var drag_event = testDrag(&t, 7, 0, 70, 50);
    drag_event.word_boundary_codepoints = &.{ ' ' };
    const sel = gesture.drag(&t, drag_event).?;

    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 0),
        false,
    ), sel);
}

test "SelectionGesture double-click drag selects by word backwards" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta gamma");

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 7, 0, time));
    try gesture.press(&t, testPress(&t, 7, 0, time));

    var drag_event = testDrag(&t, 1, 0, 10, 50);
    drag_event.word_boundary_codepoints = &.{ ' ' };
    const sel = gesture.drag(&t, drag_event).?;

    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 0),
        false,
    ), sel);
}

test "SelectionGesture double-click drag on empty cell selects nearest word" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta");

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 0, time));
    try gesture.press(&t, testPress(&t, 1, 0, time));

    var drag_event = testDrag(&t, 15, 0, 150, 50);
    drag_event.word_boundary_codepoints = &.{ ' ' };
    const sel = gesture.drag(&t, drag_event).?;

    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 0),
        false,
    ), sel);
}

test "SelectionGesture triple-click drag selects by line" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta\none two\nthree four");

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 0, time));
    try gesture.press(&t, testPress(&t, 1, 0, time));
    try gesture.press(&t, testPress(&t, 1, 0, time));

    const sel = gesture.drag(&t, testDrag(&t, 2, 2, 20, 50)).?;

    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 2),
        false,
    ), sel);
}

test "SelectionGesture triple-click drag selects by line backwards" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta\none two\nthree four");

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 2, 2, time));
    try gesture.press(&t, testPress(&t, 2, 2, time));
    try gesture.press(&t, testPress(&t, 2, 2, time));

    const sel = gesture.drag(&t, testDrag(&t, 1, 0, 10, 50)).?;

    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 2),
        false,
    ), sel);
}

test "SelectionGesture repeat increments click count" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 1, time));
    try gesture.press(&t, testPress(&t, 1, 1, time));

    try testing.expectEqual(@as(u3, 2), gesture.left_click_count);
}

test "SelectionGesture repeat clamps at triple click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    for (0..4) |_| try gesture.press(&t, testPress(&t, 1, 1, time));

    try testing.expectEqual(@as(u3, 3), gesture.left_click_count);
}

test "SelectionGesture null initial time stays single click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    try gesture.press(&t, testPress(&t, 1, 1, null));
    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expect(gesture.left_click_time != null);
}

test "SelectionGesture null repeat time stays single click" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));
    try gesture.press(&t, testPress(&t, 1, 1, null));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(@as(?std.time.Instant, null), gesture.left_click_time);
}

test "SelectionGesture distant press resets click count" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    try gesture.press(&t, testPress(&t, 1, 1, time));
    try gesture.press(&t, testPress(&t, 4, 1, time));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(@as(f64, 4), gesture.left_click_xpos);
}

test "SelectionGesture expired repeat resets click count" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    var event = testPress(&t, 1, 1, try std.time.Instant.now());
    event.repeat_interval = 0;
    try gesture.press(&t, event);

    std.Thread.sleep(std.time.ns_per_ms);
    event.time = try std.time.Instant.now();
    try gesture.press(&t, event);

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
}

test "SelectionGesture screen switch resets click count" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    const time = try std.time.Instant.now();
    const primary_tracked = t.screens.active.pages.countTrackedPins();
    try gesture.press(&t, testPress(&t, 1, 1, time));

    _ = try t.screens.getInit(testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    try gesture.press(&t, testPress(&t, 1, 1, time));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(.alternate, gesture.left_click_screen);
    try testing.expectEqual(primary_tracked, t.screens.get(.primary).?.pages.countTrackedPins());
}

test "SelectionGesture removed screen resets without untracking stale pin" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);

    _ = try t.screens.getInit(testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));

    t.screens.switchTo(.primary);
    t.screens.remove(testing.allocator, .alternate);
    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));

    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(.primary, gesture.left_click_screen);
}

test "SelectionGesture deinit untracks pin" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);

    var gesture: SelectionGesture = .init;
    const tracked = t.screens.active.pages.countTrackedPins();
    try gesture.press(&t, testPress(&t, 1, 1, try std.time.Instant.now()));
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    gesture.deinit(&t);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
