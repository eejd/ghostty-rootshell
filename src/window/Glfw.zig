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

const log = std.log.scoped(.glfw_window);

/// The glfw window handle
window: glfw.Window,

/// The glfw mouse cursor handle.
cursor: glfw.Cursor,

pub fn init(app: *const App) !Glfw {
    // Create our window
    const win = try glfw.Window.create(640, 480, "ghostty", null, null, Renderer.glfwWindowHints());
    errdefer win.destroy();

    if (builtin.mode == .Debug) {
        // Get our physical DPI - debug only because we don't have a use for
        // this but the logging of it may be useful
        const monitor = win.getMonitor() orelse monitor: {
            log.warn("window had null monitor, getting primary monitor", .{});
            break :monitor glfw.Monitor.getPrimary().?;
        };
        const physical_size = monitor.getPhysicalSize();
        const video_mode = try monitor.getVideoMode();
        const physical_x_dpi = @intToFloat(f32, video_mode.getWidth()) / (@intToFloat(f32, physical_size.width_mm) / 25.4);
        const physical_y_dpi = @intToFloat(f32, video_mode.getHeight()) / (@intToFloat(f32, physical_size.height_mm) / 25.4);
        log.debug("physical dpi x={} y={}", .{
            physical_x_dpi,
            physical_y_dpi,
        });
    }

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

    // Build our result
    return Glfw{
        .window = win,
        .cursor = cursor,
    };
}

pub fn deinit(self: *Glfw) void {
    var tabgroup_opt: if (builtin.target.isDarwin()) ?objc.Object else void = undefined;
    if (comptime builtin.target.isDarwin()) {
        const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(self.window).?);
        const tabgroup = nswindow.getProperty(objc.Object, "tabGroup");

        // On macOS versions prior to Ventura, we lose window focus on tab close
        // for some reason. We manually fix this by keeping track of the tab
        // group and just selecting the next window.
        if (internal_os.macosVersionAtLeast(13, 0, 0))
            tabgroup_opt = null
        else
            tabgroup_opt = tabgroup;

        const windows = tabgroup.getProperty(objc.Object, "windows");
        switch (windows.getProperty(usize, "count")) {
            // If we're going down to one window our tab bar is going to be
            // destroyed so unset it so that the later logic doesn't try to
            // use it.
            1 => tabgroup_opt = null,

            // If our tab bar is visible and we are going down to 1 window,
            // hide the tab bar. The check is "2" because our current window
            // is still present.
            2 => if (tabgroup.getProperty(bool, "tabBarVisible")) {
                nswindow.msgSend(void, objc.sel("toggleTabBar:"), .{nswindow.value});
            },

            else => {},
        }
    }

    // We can now safely destroy our windows. We have to do this BEFORE
    // setting up the new focused window below.
    self.window.destroy();
    self.cursor.destroy();

    // If we have a tabgroup set, we want to manually focus the next window.
    // We should NOT have to do this usually, see the comments above.
    if (comptime builtin.target.isDarwin()) {
        if (tabgroup_opt) |tabgroup| {
            const selected = tabgroup.getProperty(objc.Object, "selectedWindow");
            selected.msgSend(void, objc.sel("makeKeyWindow"), .{});
        }
    }
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
