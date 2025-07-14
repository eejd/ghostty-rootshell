const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {};
pub const Surface = struct {};
/// Functions for inter-process communication.
pub const IPC = struct {
    /// Always return false as there is no apprt to communicate with.
    pub fn sendIPC(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }
};
