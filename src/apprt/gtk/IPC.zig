//! Functions for inter-process communication.
const IPC = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");

pub const openNewWindow = @import("ipc/new_window.zig").openNewWindow;

/// Send the given IPC to a running Ghostty. Returns `true` if the action was
/// able to be performed, `false` otherwise.
pub fn sendIPC(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
    switch (action) {
        .new_window => return try openNewWindow(alloc, target, value),
    }
}

test {
    _ = openNewWindow;
}
