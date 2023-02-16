//! Application runtime implementation that uses GLFW (https://www.glfw.org/).
//!
//! This works on macOS and Linux with OpenGL and Metal.
//! (The above sentence may be out of date).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const trace = @import("tracy").trace;
const glfw = @import("glfw");
const objc = @import("objc");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const Renderer = renderer.Renderer;
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreWindow = @import("../Window.zig");

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.target.isDarwin(),
});

const log = std.log.scoped(.glfw);

pub const App = struct {
    pub const Options = struct {};

    pub fn init(_: Options) !App {
        if (!glfw.init(.{})) return error.GlfwInitFailed;
        return .{};
    }

    pub fn terminate(self: App) void {
        _ = self;
        glfw.terminate();
    }

    /// Wakeup the event loop. This should be able to be called from any thread.
    pub fn wakeup(self: App) !void {
        _ = self;
        glfw.postEmptyEvent();
    }

    /// Wait for events in the event loop to process.
    pub fn wait(self: App) !void {
        _ = self;
        glfw.waitEvents();
    }
};

pub const Window = struct {
    /// The glfw window handle
    window: glfw.Window,

    /// The glfw mouse cursor handle.
    cursor: glfw.Cursor,

    pub fn init(app: *const CoreApp, core_win: *CoreWindow) !Window {
        // Create our window
        const win = glfw.Window.create(
            640,
            480,
            "ghostty",
            null,
            null,
            Renderer.glfwWindowHints(),
        ) orelse return glfw.mustGetErrorCode();
        errdefer win.destroy();

        if (builtin.mode == .Debug) {
            // Get our physical DPI - debug only because we don't have a use for
            // this but the logging of it may be useful
            const monitor = win.getMonitor() orelse monitor: {
                log.warn("window had null monitor, getting primary monitor", .{});
                break :monitor glfw.Monitor.getPrimary().?;
            };
            const physical_size = monitor.getPhysicalSize();
            const video_mode = monitor.getVideoMode() orelse return glfw.mustGetErrorCode();
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
        const cursor = glfw.Cursor.createStandard(.ibeam) orelse return glfw.mustGetErrorCode();
        errdefer cursor.destroy();
        if ((comptime !builtin.target.isDarwin()) or internal_os.macosVersionAtLeast(13, 0, 0)) {
            // We only set our cursor if we're NOT on Mac, or if we are then the
            // macOS version is >= 13 (Ventura). On prior versions, glfw crashes
            // since we use a tab group.
            win.setCursor(cursor);
        }

        // Set our callbacks
        win.setUserPointer(core_win);
        win.setSizeCallback(sizeCallback);
        win.setCharCallback(charCallback);
        win.setKeyCallback(keyCallback);
        win.setFocusCallback(focusCallback);
        win.setRefreshCallback(refreshCallback);
        win.setScrollCallback(scrollCallback);
        win.setCursorPosCallback(cursorPosCallback);
        win.setMouseButtonCallback(mouseButtonCallback);

        // Build our result
        return Window{
            .window = win,
            .cursor = cursor,
        };
    }

    pub fn deinit(self: *Window) void {
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

    /// Set the size limits of the window.
    /// Note: this interface is not good, we should redo it if we plan
    /// to use this more. i.e. you can't set max width but no max height,
    /// or no mins.
    pub fn setSizeLimits(self: *Window, min: apprt.WindowSize, max_: ?apprt.WindowSize) !void {
        self.window.setSizeLimits(.{
            .width = min.width,
            .height = min.height,
        }, if (max_) |max| .{
            .width = max.width,
            .height = max.height,
        } else .{
            .width = null,
            .height = null,
        });
    }

    /// Returns the content scale for the created window.
    pub fn getContentScale(self: *const Window) !apprt.ContentScale {
        const scale = self.window.getContentScale();
        return apprt.ContentScale{ .x = scale.x_scale, .y = scale.y_scale };
    }

    /// Returns the size of the window in pixels. The pixel size may
    /// not match screen coordinate size but we should be able to convert
    /// back and forth using getContentScale.
    pub fn getSize(self: *const Window) !apprt.WindowSize {
        const size = self.window.getFramebufferSize();
        return apprt.WindowSize{ .width = size.width, .height = size.height };
    }

    /// Returns the cursor position in scaled pixels relative to the
    /// upper-left of the window.
    pub fn getCursorPos(self: *const Window) !apprt.CursorPos {
        const unscaled_pos = self.window.getCursorPos();
        const pos = try self.cursorPosToPixels(unscaled_pos);
        return apprt.CursorPos{
            .x = @floatCast(f32, pos.xpos),
            .y = @floatCast(f32, pos.ypos),
        };
    }

    /// Set the flag that notes this window should be closed for the next
    /// iteration of the event loop.
    pub fn setShouldClose(self: *Window) void {
        self.window.setShouldClose(true);
    }

    /// Returns true if the window is flagged to close.
    pub fn shouldClose(self: *const Window) bool {
        return self.window.shouldClose();
    }

    /// Set the title of the window.
    pub fn setTitle(self: *Window, slice: [:0]const u8) !void {
        self.window.setTitle(slice.ptr);
    }

    /// Read the clipboard. The windowing system is responsible for allocating
    /// a buffer as necessary. This should be a stable pointer until the next
    /// time getClipboardString is called.
    pub fn getClipboardString(self: *const Window) ![:0]const u8 {
        _ = self;
        return glfw.getClipboardString() orelse return glfw.mustGetErrorCode();
    }

    /// Set the clipboard.
    pub fn setClipboardString(self: *const Window, val: [:0]const u8) !void {
        _ = self;
        glfw.setClipboardString(val);
    }

    /// The cursor position from glfw directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Window, pos: glfw.Window.CursorPos) !glfw.Window.CursorPos {
        // The cursor position is in screen coordinates but we
        // want it in pixels. we need to get both the size of the
        // window in both to get the ratio to make the conversion.
        const size = self.window.getSize();
        const fb_size = self.window.getFramebufferSize();

        // If our framebuffer and screen are the same, then there is no scaling
        // happening and we can short-circuit by returning the pos as-is.
        if (fb_size.width == size.width and fb_size.height == size.height)
            return pos;

        const x_scale = @intToFloat(f64, fb_size.width) / @intToFloat(f64, size.width);
        const y_scale = @intToFloat(f64, fb_size.height) / @intToFloat(f64, size.height);
        return .{
            .xpos = pos.xpos * x_scale,
            .ypos = pos.ypos * y_scale,
        };
    }

    fn sizeCallback(window: glfw.Window, width: i32, height: i32) void {
        _ = width;
        _ = height;

        // Get the size. We are given a width/height but this is in screen
        // coordinates and we want raw pixels. The core window uses the content
        // scale to scale appropriately.
        const core_win = window.getUserPointer(CoreWindow) orelse return;
        const size = core_win.window.getSize() catch |err| {
            log.err("error querying window size for size callback err={}", .{err});
            return;
        };

        // Call the primary callback.
        core_win.sizeCallback(size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    fn charCallback(window: glfw.Window, codepoint: u21) void {
        const tracy = trace(@src());
        defer tracy.end();

        const core_win = window.getUserPointer(CoreWindow) orelse return;
        core_win.charCallback(codepoint) catch |err| {
            log.err("error in char callback err={}", .{err});
            return;
        };
    }

    fn keyCallback(
        window: glfw.Window,
        glfw_key: glfw.Key,
        scancode: i32,
        glfw_action: glfw.Action,
        glfw_mods: glfw.Mods,
    ) void {
        _ = scancode;

        const tracy = trace(@src());
        defer tracy.end();

        // Convert our glfw types into our input types
        const mods = @bitCast(input.Mods, glfw_mods);
        const action: input.Action = switch (glfw_action) {
            .release => .release,
            .press => .press,
            .repeat => .repeat,
        };
        const key: input.Key = switch (glfw_key) {
            .a => .a,
            .b => .b,
            .c => .c,
            .d => .d,
            .e => .e,
            .f => .f,
            .g => .g,
            .h => .h,
            .i => .i,
            .j => .j,
            .k => .k,
            .l => .l,
            .m => .m,
            .n => .n,
            .o => .o,
            .p => .p,
            .q => .q,
            .r => .r,
            .s => .s,
            .t => .t,
            .u => .u,
            .v => .v,
            .w => .w,
            .x => .x,
            .y => .y,
            .z => .z,
            .zero => .zero,
            .one => .one,
            .two => .three,
            .three => .four,
            .four => .four,
            .five => .five,
            .six => .six,
            .seven => .seven,
            .eight => .eight,
            .nine => .nine,
            .up => .up,
            .down => .down,
            .right => .right,
            .left => .left,
            .home => .home,
            .end => .end,
            .page_up => .page_up,
            .page_down => .page_down,
            .escape => .escape,
            .F1 => .f1,
            .F2 => .f2,
            .F3 => .f3,
            .F4 => .f4,
            .F5 => .f5,
            .F6 => .f6,
            .F7 => .f7,
            .F8 => .f8,
            .F9 => .f9,
            .F10 => .f10,
            .F11 => .f11,
            .F12 => .f12,
            .F13 => .f13,
            .F14 => .f14,
            .F15 => .f15,
            .F16 => .f16,
            .F17 => .f17,
            .F18 => .f18,
            .F19 => .f19,
            .F20 => .f20,
            .F21 => .f21,
            .F22 => .f22,
            .F23 => .f23,
            .F24 => .f24,
            .F25 => .f25,
            .kp_0 => .kp_0,
            .kp_1 => .kp_1,
            .kp_2 => .kp_2,
            .kp_3 => .kp_3,
            .kp_4 => .kp_4,
            .kp_5 => .kp_5,
            .kp_6 => .kp_6,
            .kp_7 => .kp_7,
            .kp_8 => .kp_8,
            .kp_9 => .kp_9,
            .kp_decimal => .kp_decimal,
            .kp_divide => .kp_divide,
            .kp_multiply => .kp_multiply,
            .kp_subtract => .kp_subtract,
            .kp_add => .kp_add,
            .kp_enter => .kp_enter,
            .kp_equal => .kp_equal,
            .grave_accent => .grave_accent,
            .minus => .minus,
            .equal => .equal,
            .space => .space,
            .semicolon => .semicolon,
            .apostrophe => .apostrophe,
            .comma => .comma,
            .period => .period,
            .slash => .slash,
            .left_bracket => .left_bracket,
            .right_bracket => .right_bracket,
            .backslash => .backslash,
            .enter => .enter,
            .tab => .tab,
            .backspace => .backspace,
            .insert => .insert,
            .delete => .delete,
            .caps_lock => .caps_lock,
            .scroll_lock => .scroll_lock,
            .num_lock => .num_lock,
            .print_screen => .print_screen,
            .pause => .pause,
            .left_shift => .left_shift,
            .left_control => .left_control,
            .left_alt => .left_alt,
            .left_super => .left_super,
            .right_shift => .right_shift,
            .right_control => .right_control,
            .right_alt => .right_alt,
            .right_super => .right_super,

            .menu,
            .world_1,
            .world_2,
            .unknown,
            => .invalid,
        };

        const core_win = window.getUserPointer(CoreWindow) orelse return;
        core_win.keyCallback(action, key, mods) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    fn focusCallback(window: glfw.Window, focused: bool) void {
        const tracy = trace(@src());
        defer tracy.end();

        const core_win = window.getUserPointer(CoreWindow) orelse return;
        core_win.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    fn refreshCallback(window: glfw.Window) void {
        const tracy = trace(@src());
        defer tracy.end();

        const core_win = window.getUserPointer(CoreWindow) orelse return;
        core_win.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    fn scrollCallback(window: glfw.Window, xoff: f64, yoff: f64) void {
        const tracy = trace(@src());
        defer tracy.end();

        const core_win = window.getUserPointer(CoreWindow) orelse return;
        core_win.scrollCallback(xoff, yoff) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    fn cursorPosCallback(
        window: glfw.Window,
        unscaled_xpos: f64,
        unscaled_ypos: f64,
    ) void {
        const tracy = trace(@src());
        defer tracy.end();

        const core_win = window.getUserPointer(CoreWindow) orelse return;

        // Convert our unscaled x/y to scaled.
        const pos = core_win.window.cursorPosToPixels(.{
            .xpos = unscaled_xpos,
            .ypos = unscaled_ypos,
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        core_win.cursorPosCallback(.{
            .x = @floatCast(f32, pos.xpos),
            .y = @floatCast(f32, pos.ypos),
        }) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    fn mouseButtonCallback(
        window: glfw.Window,
        glfw_button: glfw.MouseButton,
        glfw_action: glfw.Action,
        glfw_mods: glfw.Mods,
    ) void {
        const tracy = trace(@src());
        defer tracy.end();

        const core_win = window.getUserPointer(CoreWindow) orelse return;

        // Convert glfw button to input button
        const mods = @bitCast(input.Mods, glfw_mods);
        const button: input.MouseButton = switch (glfw_button) {
            .left => .left,
            .right => .right,
            .middle => .middle,
            .four => .four,
            .five => .five,
            .six => .six,
            .seven => .seven,
            .eight => .eight,
        };
        const action: input.MouseButtonState = switch (glfw_action) {
            .press => .press,
            .release => .release,
            else => unreachable,
        };

        core_win.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }
};
