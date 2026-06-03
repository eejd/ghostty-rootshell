/// A writer interface for sending commands to a tmux control mode
/// connection. This lives in the terminal (core) layer because it is
/// a protocol-level abstraction: any layer that needs to issue tmux
/// commands depends on this interface, while concrete implementations
/// live in the layer that owns the transport (termio for `ParentWriter`,
/// apprt for `SurfaceRelayWriter`).
///
/// Implementations include:
/// - `termio.Tmux.ParentWriter`: routes through the parent terminal's
///   SPSC termio mailbox (same-thread path).
/// - `apprt.surface.SurfaceRelayWriter`: routes through the MPSC app
///   mailbox for cross-thread relay to the parent surface.
pub const ControlWriter = struct {
    /// Opaque context pointer, passed to writeFn on each call.
    context: *anyopaque,

    /// Write a pre-formatted tmux command (including trailing newline)
    /// to the control mode connection. The data must not be retained
    /// past the call — implementations must copy if needed.
    writeFn: *const fn (context: *anyopaque, data: []const u8) WriteError!void,

    pub const WriteError = error{
        /// The control connection has been closed or is unavailable.
        ConnectionClosed,

        /// A transient write failure occurred.
        WriteFailed,
    };

    /// Send a command to tmux via the control connection.
    pub fn write(self: ControlWriter, data: []const u8) WriteError!void {
        return self.writeFn(self.context, data);
    }
};
