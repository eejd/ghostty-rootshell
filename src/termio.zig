//! IO implementation and utilities. The IO implementation is responsible
//! for taking the config, spinning up a child process, and handling IO
//! with the terminal.

const stream_handler = @import("termio/stream_handler.zig");

pub usingnamespace @import("termio/message.zig");
pub const backend = @import("termio/backend.zig");
pub const writer = @import("termio/writer.zig");
pub const Exec = @import("termio/Exec.zig");
pub const Options = @import("termio/Options.zig");
pub const Termio = @import("termio/Termio.zig");
pub const Thread = @import("termio/Thread.zig");
pub const Backend = backend.Backend;
pub const DerivedConfig = Termio.DerivedConfig;
pub const Mailbox = writer.Mailbox;
pub const StreamHandler = stream_handler.StreamHandler;
pub const Writer = writer.Writer;

test {
    @import("std").testing.refAllDecls(@This());

    _ = @import("termio/shell_integration.zig");
}
