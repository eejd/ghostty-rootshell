/// This is the main entrypoint to the apprt for Ghostty. Ghostty will
/// initialize this in main to start the application..
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const internal_os = @import("../../os/main.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");

const GhosttyApplication = @import("class/application.zig").GhosttyApplication;
const Surface = @import("Surface.zig");
const gtk_version = @import("gtk_version.zig");
const adw_version = @import("adw_version.zig");

const log = std.log.scoped(.gtk);

/// The GObject GhosttyApplication instance
app: *GhosttyApplication,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;

    const app: *GhosttyApplication = try .new(core_app);
    errdefer app.unref();
    self.* = .{ .app = app };
    return;
}

pub fn run(self: *App) !void {
    try self.app.run(self);
}

pub fn terminate(self: *App) void {
    // We force deinitialize the app. We don't unref because other things
    // tend to have a reference at this point, so this just forces the
    // disposal now.
    self.app.deinit();
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = self;
    _ = target;
    _ = value;
    return false;
}

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    _ = alloc;
    _ = target;
    _ = value;
    return false;
}

/// Close the given surface.
pub fn redrawSurface(self: *App, surface: *Surface) void {
    _ = self;
    _ = surface;
}

/// Redraw the inspector for the given surface.
pub fn redrawInspector(self: *App, surface: *Surface) void {
    _ = self;
    _ = surface;
}
