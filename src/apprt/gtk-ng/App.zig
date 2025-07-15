const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = self;
    _ = core_app;
    _ = opts;
    return;
}

pub fn run(self: *App) !void {
    _ = self;
}

pub fn terminate(self: *App) void {
    _ = self;
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
