const Surface = @This();

const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");

core_surface: CoreSurface,

pub fn deinit(self: *Surface) void {
    _ = self;
}

pub fn close(self: *Surface, process_active: bool) void {
    _ = self;
    _ = process_active;
}

pub fn shouldClose(self: *Surface) bool {
    _ = self;
    return false;
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    _ = self;
    return null;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    _ = self;
    return .{ .x = 1, .y = 1 };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    _ = self;
    return .{ .x = 0, .y = 0 };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !void {
    _ = self;
    _ = clipboard_type;
    _ = state;
}

pub fn setClipboardString(
    self: *Surface,
    val: [:0]const u8,
    clipboard_type: apprt.Clipboard,
    confirm: bool,
) !void {
    _ = self;
    _ = val;
    _ = clipboard_type;
    _ = confirm;
}
