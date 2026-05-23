const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const grid_ref = @import("grid_ref.zig");
const point = @import("../point.zig");
const Selection = @import("../Selection.zig");
const Result = @import("result.zig").Result;
const terminal_c = @import("terminal.zig");

const log = std.log.scoped(.selection_c);

pub const Adjustment = Selection.Adjustment;
pub const Order = Selection.Order;

/// C: GhosttySelection
pub const CSelection = extern struct {
    size: usize = @sizeOf(CSelection),
    start: grid_ref.CGridRef,
    end: grid_ref.CGridRef,
    rectangle: bool = false,

    pub fn toZig(self: CSelection) ?Selection {
        const start_pin = self.start.toPin() orelse return null;
        const end_pin = self.end.toPin() orelse return null;
        return Selection.init(start_pin, end_pin, self.rectangle);
    }

    pub fn fromZig(sel: Selection) CSelection {
        return .{
            .start = .fromPin(sel.start()),
            .end = .fromPin(sel.end()),
            .rectangle = sel.rectangle,
        };
    }
};

pub fn adjust(
    terminal: terminal_c.Terminal,
    selection: ?*CSelection,
    adjustment: Selection.Adjustment,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Selection.Adjustment, @intFromEnum(adjustment)) catch {
            log.warn("terminal_selection_adjust invalid adjustment value={d}", .{@intFromEnum(adjustment)});
            return .invalid_value;
        };
    }

    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel_ptr = selection orelse return .invalid_value;
    var sel = sel_ptr.toZig() orelse return .invalid_value;
    sel.adjust(t.screens.active, adjustment);
    sel_ptr.* = .fromZig(sel);
    return .success;
}

pub fn order(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    out_order: ?*Selection.Order,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_order orelse return .invalid_value;
    if (!valid(t, sel)) return .invalid_value;

    out.* = sel.order(t.screens.active);
    return .success;
}

pub fn ordered(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    desired: Selection.Order,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Selection.Order, @intFromEnum(desired)) catch {
            log.warn("terminal_selection_ordered invalid desired value={d}", .{@intFromEnum(desired)});
            return .invalid_value;
        };
    }

    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_selection orelse return .invalid_value;
    if (!valid(t, sel)) return .invalid_value;

    out.* = .fromZig(sel.ordered(t.screens.active, desired));
    return .success;
}

pub fn contains(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    pt: point.Point.C,
    out_contains: ?*bool,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_contains orelse return .invalid_value;
    if (!valid(t, sel)) return .invalid_value;

    const screen = t.screens.active;
    const pin = screen.pages.pin(.fromC(pt)) orelse return .invalid_value;
    out.* = sel.contains(screen, pin);
    return .success;
}

pub fn equal(
    terminal: terminal_c.Terminal,
    a: ?*const CSelection,
    b: ?*const CSelection,
    out_equal: ?*bool,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel_a = (a orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const sel_b = (b orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_equal orelse return .invalid_value;
    if (!valid(t, sel_a) or !valid(t, sel_b)) return .invalid_value;

    out.* = sel_a.eql(sel_b);
    return .success;
}

pub fn validate(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    if (!valid(t, sel)) return .invalid_value;

    return .success;
}

fn valid(t: *terminal_c.ZigTerminal, sel: Selection) bool {
    const screen = t.screens.active;
    return screen.pages.pointFromPin(.screen, sel.start()) != null and
        screen.pages.pointFromPin(.screen, sel.end()) != null;
}
