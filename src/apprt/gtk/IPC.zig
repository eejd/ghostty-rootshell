//! Functions for inter-process communication.
const IPC = @This();

pub const openNewWindow = @import("ipc/new_window.zig").openNewWindow;

test {
    _ = openNewWindow;
}
