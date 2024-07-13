//! IO implementation and utilities. The IO implementation is responsible
//! for taking the config, spinning up a child process, and handling IO
//! with the terminal.

pub usingnamespace @import("termio/message.zig");
pub const Exec = @import("termio/Exec.zig");
pub const Options = @import("termio/Options.zig");
pub const Termio = @import("termio/Termio.zig");
pub const Thread = @import("termio/Thread.zig");
pub const Mailbox = Thread.Mailbox;

test {
    @import("std").testing.refAllDecls(@This());

    _ = @import("termio/shell_integration.zig");
}
