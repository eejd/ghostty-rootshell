//! Window implementation that uses GLFW (https://www.glfw.org/).
pub const Glfw = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const objc = @import("objc");
const App = @import("../App.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const Renderer = renderer.Renderer;
const window = @import("../window.zig");

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.target.isDarwin(),
});

/// The glfw window handle
window: glfw.Window,

/// The glfw mouse cursor handle.
cursor: glfw.Cursor,

pub fn init(app: *const App) !Glfw {
    // Create our window
    const win = try glfw.Window.create(640, 480, "ghostty", null, null, Renderer.windowHints());
    errdefer win.destroy();
    try Renderer.windowInit(win);

    // On Mac, enable tabbing
    if (comptime builtin.target.isDarwin()) {
        const NSWindowTabbingMode = enum(usize) { automatic = 0, preferred = 1, disallowed = 2 };
        const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(win).?);

        // Tabbing mode enables tabbing at all
        nswindow.setProperty("tabbingMode", NSWindowTabbingMode.automatic);

        // All windows within a tab bar must have a matching tabbing ID.
        // The app sets this up for us.
        nswindow.setProperty("tabbingIdentifier", app.darwin.tabbing_id);
    }

    // Create the cursor
    const cursor = try glfw.Cursor.createStandard(.ibeam);
    errdefer cursor.destroy();
    if ((comptime !builtin.target.isDarwin()) or internal_os.macosVersionAtLeast(13, 0, 0)) {
        // We only set our cursor if we're NOT on Mac, or if we are then the
        // macOS version is >= 13 (Ventura). On prior versions, glfw crashes
        // since we use a tab group.
        try win.setCursor(cursor);
    }

    return Glfw{
        .window = win,
        .cursor = cursor,
    };
}

pub fn deinit(self: *Glfw) void {
    self.window.destroy();
    self.cursor.destroy();
}

/// Returns the content scale for the created window.
pub fn getContentScale(self: *const Glfw) !window.ContentScale {
    const scale = try self.window.getContentScale();
    return window.ContentScale{ .x = scale.x_scale, .y = scale.y_scale };
}

/// Returns the size of the window in screen coordinates.
pub fn getSize(self: *const Glfw) !window.Size {
    const size = try self.window.getSize();
    return window.Size{ .width = size.width, .height = size.height };
}
