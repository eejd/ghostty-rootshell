//! This file contains the implementation for tmux control mode. See
//! tmux(1) for more information on control mode. Some basics are documented
//! here but this is not meant to be a comprehensive source of protocol
//! documentation.

const std = @import("std");
const assert = std.debug.assert;

const log = std.log.scoped(.terminal_tmux);

/// A tmux control mode client. It is expected that the caller establishes
/// the connection in some way (i.e. detects the opening DCS sequence). This
/// just works on a byte stream.
pub const Client = struct {
    /// Current state of the client.
    state: State = .idle,

    /// The buffer used to store in-progress commands, output, etc.
    buffer: std.ArrayList(u8),

    /// The maximum size in bytes of the buffer. This is used to limit
    /// memory usage. If the buffer exceeds this size, the client will
    /// enter a broken state (the control mode session will be forcibly
    /// exited and future data dropped).
    max_bytes: usize = 1024 * 1024,

    const State = enum {
        /// Outside of any active command. This should drop any output
        /// unless it is '%' on the first byte of a line.
        idle,

        /// We experienced unexpected input and are in a broken state
        /// so we cannot continue processing.
        broken,

        /// Inside an active command (started with '%').
        command,

        /// Inside a begin/end block.
        block,
    };

    pub fn deinit(self: *Client) void {
        self.buffer.deinit();
    }

    // Handle a byte of input.
    pub fn put(self: *Client, byte: u8) !?Notification {
        if (self.buffer.items.len >= self.max_bytes) {
            self.broken();
            return error.OutOfMemory;
        }

        switch (self.state) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Waiting for a command so if the byte is not '%' then
            // we're in a broken state. Return an exit command.
            .idle => if (byte != '%') {
                self.broken();
                return .{ .exit = {} };
            } else {
                self.state = .command;
            },

            // If we're in a command and its not a newline then
            // we accumulate. If it is a newline then we have a
            // complete command we need to parse.
            .command => if (byte == '\n') {
                // We have a complete command, parse it.
                return try self.parseNotification();
            },

            // If we're ina block then we accumulate until we see a newline
            // and then we check to see if that line ended the block.
            .block => if (byte == '\n') {
                const idx = if (std.mem.lastIndexOfScalar(
                    u8,
                    self.buffer.items,
                    '\n',
                )) |v| v + 1 else 0;
                const line = self.buffer.items[idx..];
                if (std.mem.startsWith(u8, line, "%end") or
                    std.mem.startsWith(u8, line, "%error"))
                {
                    // If it is an error then log it.
                    if (std.mem.startsWith(u8, line, "%error")) {
                        const output = self.buffer.items[0..idx];
                        log.warn("tmux control mode error={s}", .{output});
                    }

                    // We ignore the rest of the line, see %begin for why.
                    self.state = .idle;
                    self.buffer.clearRetainingCapacity();
                    return null;
                }
            },
        }

        try self.buffer.append(byte);

        return null;
    }

    fn parseNotification(self: *Client) !?Notification {
        assert(self.state == .command);

        var it = std.mem.tokenizeScalar(u8, self.buffer.items, ' ');

        // The command MUST exist because we guard entering the command
        // state on seeing at least a '%'.
        const cmd = it.next().?;
        if (std.mem.eql(u8, cmd, "%begin")) {
            // We don't use the rest of the tokens for now because tmux
            // claims to guarantee that begin/end are always in order and
            // never intermixed. In the future, we should probably validate
            // this.
            // TODO(tmuxcc): do this before merge?

            // Move to block state because we expect a corresponding end/error
            // and want to accumulate the data.
            self.state = .block;
            self.buffer.clearRetainingCapacity();
            return null;
        } else {
            // Unknown command, log it and return to idle state.
            log.warn("unknown tmux control mode command={s}", .{cmd});
        }

        // Successful exit, revert to idle state.
        self.buffer.clearRetainingCapacity();
        self.state = .idle;

        return null;
    }

    // Mark the tmux state as broken.
    fn broken(self: *Client) void {
        self.state = .broken;
        self.buffer.clearAndFree();
    }
};

/// Possible notification types from tmux control mode. These are documented
/// in tmux(1).
pub const Notification = union(enum) {
    enter: void,
    exit: void,
};

test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Client = .{ .buffer = std.ArrayList(u8).init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
}

test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Client = .{ .buffer = std.ArrayList(u8).init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
}
