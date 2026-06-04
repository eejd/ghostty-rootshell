//! This file contains the implementation for tmux control mode. See
//! tmux(1) for more information on control mode. Some basics are documented
//! here but this is not meant to be a comprehensive source of protocol
//! documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;

const log = std.log.scoped(.terminal_tmux);

/// A tmux control mode parser. This takes in output from tmux control
/// mode and parses it into a structured notifications.
///
/// It is up to the caller to establish the connection to the tmux
/// control mode session in some way (e.g. via exec, a network socket,
/// whatever). This is fully agnostic to how the data is received and sent.
pub const Parser = struct {
    /// Current state of the client.
    state: State = .idle,

    /// The buffer used to store in-progress notifications, output, etc.
    buffer: std.Io.Writer.Allocating,

    /// The maximum size in bytes of the buffer. This is used to limit
    /// memory usage. If the buffer exceeds this size, the client will
    /// enter a broken state (the control mode session will be forcibly
    /// exited and future data dropped).
    ///
    /// This must comfortably exceed the largest single notification or
    /// command-response block tmux can send. The big one is a `capture-pane
    /// -e -S -` history replay (on attach, or for a new pane): `-e` emits SGR
    /// escapes per color run and `-S -` dumps the pane's entire history (tmux's
    /// history-limit, default 2000 lines but often raised), so a wide, colorful
    /// pane easily exceeds 1 MiB. The previous 1 MiB cap broke the parser
    /// mid-restore over SSH/tssh (large captures arrive in many fragments and
    /// blow the cap), leaving a dead control channel and a blank/partial pane.
    /// iTerm2's gateway buffers command responses unbounded; we keep a generous
    /// ceiling instead, only to bound a runaway/malicious server on iOS. The
    /// buffer holds one block at a time and is freed/cleared after each, so this
    /// is a transient ceiling, not a reservation.
    max_bytes: usize = 64 * 1024 * 1024,

    /// Tokens from the most recent %begin line, used to validate that
    /// the corresponding %end/%error matches. Null if %begin could not
    /// be parsed (validation is skipped in that case).
    block_begin: ?BlockInfo = null,

    /// Parsed tokens from a %begin, %end, or %error guard line.
    /// tmux guarantees these match between begin and end/error.
    const BlockInfo = struct {
        time: usize,
        command_id: usize,
        flags: usize,
    };

    const State = enum {
        /// Outside of any active notifications. This should drop any output
        /// unless it is '%' on the first byte of a line. The buffer will be
        /// cleared when it sees '%', this is so that the previous notification
        /// data is valid until we receive/process new data.
        idle,

        /// We experienced unexpected input and are in a broken state
        /// so we cannot continue processing. When this state is set,
        /// the buffer has been deinited and must not be accessed.
        broken,

        /// Inside an active notification (started with '%').
        notification,

        /// Inside a begin/end block.
        block,
    };

    pub fn deinit(self: *Parser) void {
        // If we're in a broken state, we already deinited
        // the buffer, so we don't need to do anything.
        if (self.state == .broken) return;

        self.buffer.deinit();
    }

    // Handle a byte of input.
    //
    // If we reach our byte limit this will return OutOfMemory. It only
    // does this on the first time we exceed the limit; subsequent calls
    // will return null as we drop all input in a broken state.
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        // If we're in a broken state, just do nothing.
        //
        // We have to do this check here before we check the buffer, because if
        // we're in a broken state then we'd have already deinited the buffer.
        if (self.state == .broken) return null;

        if (self.buffer.written().len >= self.max_bytes) {
            log.warn("tmux control buffer exceeded {} bytes; breaking control channel", .{self.max_bytes});
            self.broken();
            return error.OutOfMemory;
        }

        switch (self.state) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Waiting for a notification so if the byte is not '%' then
            // we're in a broken state. Control mode output should always
            // be wrapped in '%begin/%end' orelse we expect a notification.
            // Return an exit notification.
            .idle => if (byte != '%') {
                self.broken();
                return .{ .exit = {} };
            } else {
                self.buffer.clearRetainingCapacity();
                self.state = .notification;
            },

            // If we're in a notification and its not a newline then
            // we accumulate. If it is a newline then we have a
            // complete notification we need to parse.
            .notification => if (byte == '\n') {
                // We have a complete notification, parse it.
                return self.parseNotification() catch {
                    // If parsing failed, then we do not mark the state
                    // as broken because we may be able to continue parsing
                    // other types of notifications.
                    //
                    // In the future we may want to emit a notification
                    // here about unknown or unsupported notifications.
                    return null;
                };
            },

            // If we're in a block then we accumulate until we see a newline
            // and then we check to see if that line ended the block.
            .block => if (byte == '\n') {
                const written = self.buffer.written();
                const idx = if (std.mem.lastIndexOfScalar(
                    u8,
                    written,
                    '\n',
                )) |v| v + 1 else 0;
                const line = written[idx..];

                if (parseBlockTerminator(line)) |result| {
                    // Validate that end/error tokens match the begin tokens.
                    // tmux guarantees these match, so a mismatch indicates
                    // a protocol error or interleaving bug. We log but still
                    // process the block (per Ghostty error resilience convention).
                    if (self.block_begin) |begin| {
                        if (begin.time != result.info.time or
                            begin.command_id != result.info.command_id or
                            begin.flags != result.info.flags)
                        {
                            log.warn(
                                "block begin/end mismatch: begin=({},{},{}) end=({},{},{})",
                                .{
                                    begin.time,       begin.command_id,       begin.flags,
                                    result.info.time, result.info.command_id, result.info.flags,
                                },
                            );
                        }
                    }
                    self.block_begin = null;

                    const output = std.mem.trimRight(
                        u8,
                        written[0..idx],
                        "\r\n",
                    );

                    // Important: do not clear buffer since the notification
                    // contains it.
                    self.state = .idle;
                    switch (result.terminator) {
                        .end => return .{ .block_end = output },
                        .err => {
                            log.warn("tmux control mode error={s}", .{output});
                            return .{ .block_err = output };
                        },
                    }
                }

                // Didn't end the block, continue accumulating.
            },
        }

        self.buffer.writer.writeByte(byte) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        return null;
    }

    /// Whether a 7-bit ST (`ESC \`) seen by the DCS handler right now should be
    /// honored as the tmux control-mode terminator. Only true between
    /// notifications (`idle`) or once broken — that's where tmux's real closing
    /// ST appears (it follows a `%exit` line, which resets us to idle). Inside a
    /// notification or a command-response block, `ESC \` is content (e.g. an OSC
    /// string terminator embedded in a `capture-pane -e` history replay during
    /// attach) and must be forwarded, not treated as the end of control mode —
    /// otherwise the remainder of the DCS stream leaks into the terminal.
    pub fn canTerminate(self: *const Parser) bool {
        return self.state == .idle or self.state == .broken;
    }

    const ParseError = error{RegexError};

    const BlockTerminator = enum { end, err };

    const BlockTerminatorResult = struct {
        terminator: BlockTerminator,
        info: BlockInfo,
    };

    /// Block payload is raw data, so a line only terminates a block if it
    /// exactly matches tmux's `%end`/`%error` guard-line shape.
    fn parseBlockTerminator(line_raw: []const u8) ?BlockTerminatorResult {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = fields.next() orelse return null;
        const terminator: BlockTerminator = if (std.mem.eql(u8, cmd, "%end"))
            .end
        else if (std.mem.eql(u8, cmd, "%error"))
            .err
        else
            return null;

        const time_str = fields.next() orelse return null;
        const command_id_str = fields.next() orelse return null;
        const flags_str = fields.next() orelse return null;
        const extra = fields.next();

        const time = std.fmt.parseInt(usize, time_str, 10) catch return null;
        const command_id = std.fmt.parseInt(usize, command_id_str, 10) catch return null;
        const flags = std.fmt.parseInt(usize, flags_str, 10) catch return null;
        if (extra != null) return null;

        return .{
            .terminator = terminator,
            .info = .{ .time = time, .command_id = command_id, .flags = flags },
        };
    }

    /// Parse BlockInfo from a %begin line. Format: %begin <time> <command_id> <flags>
    fn parseBeginInfo(line: []const u8) ?BlockInfo {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = fields.next() orelse return null;
        if (!std.mem.eql(u8, cmd, "%begin")) return null;

        const time_str = fields.next() orelse return null;
        const command_id_str = fields.next() orelse return null;
        const flags_str = fields.next() orelse return null;
        if (fields.next() != null) return null; // unexpected extra fields

        return .{
            .time = std.fmt.parseInt(usize, time_str, 10) catch return null,
            .command_id = std.fmt.parseInt(usize, command_id_str, 10) catch return null,
            .flags = std.fmt.parseInt(usize, flags_str, 10) catch return null,
        };
    }

    // -- Byte-level notification field helpers ------------------------------
    //
    // Notifications are parsed as raw bytes, NOT via a UTF-8 regex. tmux sends
    // raw, frequently UTF-8-split bytes in `%output`/`%extended-output` payloads
    // (it escapes only bytes < 0x20 and '\\'; see tmux `control.c`). A UTF-8
    // regex drops or truncates a payload that ends mid-character (a glyph split
    // across two consecutive notifications), producing U+FFFD "diamonds" and
    // lost output. iTerm2's TmuxGateway parses %output at the byte level for the
    // same reason. Byte parsing also avoids compiling a regex per notification.

    /// The bytes of `line` after the command word and its single separating
    /// space. `cmd` must be the leading word of `line`. Null if nothing follows.
    fn afterCmd(line: []const u8, cmd: []const u8) ?[]const u8 {
        if (line.len <= cmd.len) return null;
        // line[cmd.len] is guaranteed to be the separating space.
        return line[cmd.len + 1 ..];
    }

    const SigilInt = struct { value: usize, rest: []const u8 };

    /// Parse `<sigil><digits>` at the start of `s` (e.g. `%42`, `$3`, `@7`) and
    /// return the value plus the bytes following the digits. Null if the sigil
    /// is missing or no digits follow it.
    fn parseSigilInt(s: []const u8, sigil: u8) ?SigilInt {
        if (s.len < 2 or s[0] != sigil) return null;
        var i: usize = 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == 1) return null; // no digits after the sigil
        const value = std.fmt.parseInt(usize, s[1..i], 10) catch return null;
        return .{ .value = value, .rest = s[i..] };
    }

    /// Require `s` to begin with a space and return the bytes after it. Null
    /// otherwise (the caller treats a missing space as a malformed line).
    fn afterSpace(s: []const u8) ?[]const u8 {
        if (s.len == 0 or s[0] != ' ') return null;
        return s[1..];
    }

    const NextField = struct { token: []const u8, rest: []const u8 };

    /// Split off the first space-delimited field of `s`. `rest` is the bytes
    /// after the single separating space (empty when the space is last/absent).
    fn nextField(s: []const u8) NextField {
        if (std.mem.indexOfScalar(u8, s, ' ')) |i| {
            return .{ .token = s[0..i], .rest = s[i + 1 ..] };
        }
        return .{ .token = s, .rest = "" };
    }

    fn parseNotification(self: *Parser) ParseError!?Notification {
        assert(self.state == .notification);

        const line = line: {
            var line = self.buffer.written();
            if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            break :line line;
        };
        const cmd = cmd: {
            const idx = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            break :cmd line[0..idx];
        };

        // The notification MUST exist because we guard entering the notification
        // state on seeing at least a '%'.
        if (std.mem.eql(u8, cmd, "%begin")) {
            // Parse the begin tokens so we can validate the matching
            // end/error. The format is: %begin <time> <command_id> <flags>
            self.block_begin = parseBeginInfo(line);
            if (self.block_begin == null) {
                log.info("failed to parse %begin tokens: {s}", .{line});
            }

            // Move to block state because we expect a corresponding end/error
            // and want to accumulate the data.
            self.state = .block;
            self.buffer.clearRetainingCapacity();
            return null;
        } else if (std.mem.eql(u8, cmd, "%output")) cmd: {
            // Byte-level parse (see helper comment above). The payload is passed
            // through verbatim; the persistent per-pane VT decoder reassembles
            // multibyte sequences that tmux split across notifications.
            // Format: %output %<pane-id> <data>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const id = parseSigilInt(after, '%') orelse break :cmd;
            const data = afterSpace(id.rest) orelse break :cmd;

            // Important: do not clear buffer here since data points to it
            self.state = .idle;
            return .{ .output = .{ .pane_id = id.value, .data = data } };
        } else if (std.mem.eql(u8, cmd, "%session-changed")) cmd: {
            // Format: %session-changed $<id> <name>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const id = parseSigilInt(after, '$') orelse break :cmd;
            const name = afterSpace(id.rest) orelse break :cmd;

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_changed = .{ .id = id.value, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%sessions-changed")) cmd: {
            if (!std.mem.eql(u8, line, "%sessions-changed")) {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            }

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .sessions_changed = {} };
        } else if (std.mem.eql(u8, cmd, "%session-window-changed")) cmd: {
            // Format: %session-window-changed $<session-id> @<window-id>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const sid = parseSigilInt(after, '$') orelse break :cmd;
            const rest = afterSpace(sid.rest) orelse break :cmd;
            const wid = parseSigilInt(rest, '@') orelse break :cmd;
            if (wid.rest.len != 0) break :cmd;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .session_window_changed = .{ .session_id = sid.value, .window_id = wid.value } };
        } else if (std.mem.eql(u8, cmd, "%layout-change")) cmd: {
            // Format: %layout-change @<id> <layout> <visible-layout> <flags>
            // layout/visible-layout never contain spaces; flags is optional.
            const after = afterCmd(line, cmd) orelse break :cmd;
            const id = parseSigilInt(after, '@') orelse break :cmd;
            const f0 = afterSpace(id.rest) orelse break :cmd;
            const layout_field = nextField(f0);
            if (layout_field.token.len == 0) break :cmd;
            const visible_field = nextField(layout_field.rest);
            if (visible_field.token.len == 0) break :cmd;

            // Important: do not clear buffer here since layout strings point to it
            self.state = .idle;
            return .{ .layout_change = .{
                .window_id = id.value,
                .layout = layout_field.token,
                .visible_layout = visible_field.token,
                .raw_flags = visible_field.rest,
            } };
        } else if (std.mem.eql(u8, cmd, "%window-add")) cmd: {
            // Format: %window-add @<id>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const id = parseSigilInt(after, '@') orelse break :cmd;
            if (id.rest.len != 0) break :cmd;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_add = .{ .id = id.value } };
        } else if (std.mem.eql(u8, cmd, "%window-close")) cmd: {
            // Format: %window-close @<id>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const id = parseSigilInt(after, '@') orelse break :cmd;
            if (id.rest.len != 0) break :cmd;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_close = .{ .id = id.value } };
        } else if (std.mem.eql(u8, cmd, "%window-renamed")) cmd: {
            // Format: %window-renamed @<id> <name>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const id = parseSigilInt(after, '@') orelse break :cmd;
            const name = afterSpace(id.rest) orelse break :cmd;

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .window_renamed = .{ .id = id.value, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%window-pane-changed")) cmd: {
            // Format: %window-pane-changed @<window-id> %<pane-id>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const wid = parseSigilInt(after, '@') orelse break :cmd;
            const rest = afterSpace(wid.rest) orelse break :cmd;
            const pid = parseSigilInt(rest, '%') orelse break :cmd;
            if (pid.rest.len != 0) break :cmd;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_pane_changed = .{ .window_id = wid.value, .pane_id = pid.value } };
        } else if (std.mem.eql(u8, cmd, "%client-detached")) cmd: {
            // Format: %client-detached <client>
            const after = afterCmd(line, cmd) orelse break :cmd;

            // Important: do not clear buffer here since client points to it
            self.state = .idle;
            return .{ .client_detached = .{ .client = after } };
        } else if (std.mem.eql(u8, cmd, "%client-session-changed")) cmd: {
            // Format: %client-session-changed <client> $<session-id> <name>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const client_field = nextField(after);
            if (client_field.token.len == 0) break :cmd;
            const sid = parseSigilInt(client_field.rest, '$') orelse break :cmd;
            const name = afterSpace(sid.rest) orelse break :cmd;

            // Important: do not clear buffer here since client/name point to it
            self.state = .idle;
            return .{ .client_session_changed = .{ .client = client_field.token, .session_id = sid.value, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%pane-mode-changed")) cmd: {
            // Format: %pane-mode-changed %<pane-id>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const pid = parseSigilInt(after, '%') orelse break :cmd;
            if (pid.rest.len != 0) break :cmd;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .pane_mode_changed = .{ .pane_id = pid.value } };
        } else if (std.mem.eql(u8, cmd, "%session-renamed")) cmd: {
            // Format: %session-renamed <name>
            const after = afterCmd(line, cmd) orelse break :cmd;

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_renamed = .{ .name = after } };
        } else if (std.mem.eql(u8, cmd, "%pause")) cmd: {
            // Format: %pause %<pane-id>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const pid = parseSigilInt(after, '%') orelse break :cmd;
            if (pid.rest.len != 0) break :cmd;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .pause = .{ .pane_id = pid.value } };
        } else if (std.mem.eql(u8, cmd, "%continue")) cmd: {
            // Format: %continue %<pane-id>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const pid = parseSigilInt(after, '%') orelse break :cmd;
            if (pid.rest.len != 0) break :cmd;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .@"continue" = .{ .pane_id = pid.value } };
        } else if (std.mem.eql(u8, cmd, "%exit")) {
            // The tmux server is exiting or has detached. The optional reason
            // string is dropped (see Notification.exit comment).
            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .exit = {} };
        } else if (std.mem.eql(u8, cmd, "%extended-output")) cmd: {
            // Extended output: sent instead of %output when pause-after is
            // enabled. Same raw-bytes rationale as %output (byte-level parse,
            // payload passed through verbatim).
            // Format: %extended-output %<pane-id> <age-ms> [more args] : <data>
            const after = afterCmd(line, cmd) orelse break :cmd;
            const id = parseSigilInt(after, '%') orelse break :cmd;
            const after_id = afterSpace(id.rest) orelse break :cmd;
            const age_field = nextField(after_id);
            const age_ms = std.fmt.parseInt(usize, age_field.token, 10) catch break :cmd;
            // tmux separates the (possibly extended) header from the payload
            // with a " : " delimiter. Locate it as raw bytes; everything after
            // it is the verbatim payload.
            const delim = std.mem.indexOf(u8, age_field.rest, ": ") orelse break :cmd;
            const raw_data = age_field.rest[delim + 2 ..];

            // Important: do not clear buffer here since raw_data points to it
            self.state = .idle;
            return .{ .extended_output = .{
                .pane_id = id.value,
                .age_ms = age_ms,
                .data = raw_data,
            } };
        } else if (std.mem.eql(u8, cmd, "%message")) cmd: {
            // Format: %message <text>
            const after = afterCmd(line, cmd) orelse break :cmd;

            // Important: do not clear buffer here since text points to it
            self.state = .idle;
            return .{ .message = .{ .text = after } };
        } else if (std.mem.eql(u8, cmd, "%unlinked-window-add") or
            std.mem.eql(u8, cmd, "%unlinked-window-close") or
            std.mem.eql(u8, cmd, "%unlinked-window-renamed") or
            std.mem.eql(u8, cmd, "%paste-buffer-changed") or
            std.mem.eql(u8, cmd, "%paste-buffer-deleted") or
            std.mem.eql(u8, cmd, "%subscription-changed"))
        {
            // Recognized but intentionally ignored notifications. These relate
            // to other sessions' windows, clipboard buffers, or format
            // subscriptions that we do not currently use.
            log.debug("ignoring tmux notification: {s}", .{cmd});
        } else {
            // Unknown notification, log it and return to idle state.
            log.warn("unknown tmux control mode notification={s}", .{cmd});
        }

        // Unknown command. Clear the buffer and return to idle state.
        self.buffer.clearRetainingCapacity();
        self.state = .idle;

        return null;
    }

    // Mark the tmux state as broken.
    fn broken(self: *Parser) void {
        self.state = .broken;
        self.buffer.deinit();
    }
};

/// Possible notification types from tmux control mode. These are documented
/// in tmux(1). A lot of the simple documentation was copied from that man
/// page here.
///
/// Lifetime: all slice fields (`[]const u8`) within a notification point
/// into the parser's internal buffer and are valid only until the next
/// call to `next()`.
pub const Notification = union(enum) {
    /// Entering tmux control mode. This isn't an actual event sent by
    /// tmux but is one sent by us to indicate that we have detected that
    /// tmux control mode is starting.
    enter,

    /// Exit.
    ///
    /// NOTE: The tmux protocol contains a "reason" string (human friendly)
    /// associated with this. We currently drop it because we don't need it
    /// but this may be something we want to add later. If we do add it,
    /// we have to consider buffer limits and how we handle those (dropping
    /// vs truncating, etc.).
    exit,

    /// Dispatched at the end of a begin/end block with the raw data.
    /// The control mode parser can't parse the data because it is unaware
    /// of the command that was sent to trigger this output.
    block_end: []const u8,
    block_err: []const u8,

    /// Raw output from a pane.
    output: struct {
        pane_id: usize,
        data: []const u8, // raw from protocol (octal-escaped by tmux)
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    session_changed: struct {
        id: usize,
        name: []const u8,
    },

    /// A session was created or destroyed.
    sessions_changed,

    /// The active window in the session with ID session-id changed to
    /// the window with ID window-id.
    session_window_changed: struct {
        session_id: usize,
        window_id: usize,
    },

    /// The layout of the window with ID window-id changed.
    layout_change: struct {
        window_id: usize,
        layout: []const u8,
        visible_layout: []const u8,
        raw_flags: []const u8,
    },

    /// The window with ID window-id was linked to the current session.
    window_add: struct {
        id: usize,
    },

    /// The window with ID window-id was closed.
    window_close: struct {
        id: usize,
    },

    /// The window with ID window-id was renamed to name.
    window_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// The active pane in the window with ID window-id changed to the pane
    /// with ID pane-id.
    window_pane_changed: struct {
        window_id: usize,
        pane_id: usize,
    },

    /// The client has detached.
    client_detached: struct {
        client: []const u8,
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    client_session_changed: struct {
        client: []const u8,
        session_id: usize,
        name: []const u8,
    },

    /// The pane with ID pane-id has changed mode (e.g. entered/exited
    /// copy mode).
    pane_mode_changed: struct {
        pane_id: usize,
    },

    /// The current session was renamed to name.
    session_renamed: struct {
        name: []const u8,
    },

    /// The pane has been paused (if the pause-after flag is set).
    pause: struct {
        pane_id: usize,
    },

    /// The pane has been continued after being paused.
    @"continue": struct {
        pane_id: usize,
    },

    /// Extended output from a pane. Sent instead of `%output` when the
    /// `pause-after` flag is set on the client. Contains an age in
    /// milliseconds since the output was produced.
    extended_output: struct {
        pane_id: usize,
        age_ms: usize,
        data: []const u8, // raw from protocol (octal-escaped by tmux)
    },

    /// A message sent with the display-message command, or an
    /// informational/error message from the tmux server.
    message: struct {
        text: []const u8,
    },

    pub fn format(self: Notification, writer: *std.Io.Writer) !void {
        const T = Notification;
        const info = @typeInfo(T).@"union";

        try writer.writeAll(@typeName(T));
        if (info.tag_type) |TagType| {
            try writer.writeAll("{ .");
            try writer.writeAll(@tagName(@as(TagType, self)));
            try writer.writeAll(" = ");

            inline for (info.fields) |u_field| {
                if (self == @field(TagType, u_field.name)) {
                    const value = @field(self, u_field.name);
                    switch (u_field.type) {
                        []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                        else => try writer.print("{any}", .{value}),
                    }
                }
            }

            try writer.writeAll(" }");
        }
    }
};

test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("", n.block_end);
}

test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("", n.block_err);
}

test "tmux begin/end data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\nworld\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello\nworld", n.block_end);
}

test "tmux block payload may start with %end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end not really\nhello", n.block_end);
}

test "tmux block payload may start with %error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%error not really\nhello", n.block_end);
}

test "tmux block may terminate with real %error after misleading payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("%error not really\nhello", n.block_err);
}

test "tmux block terminator requires exact token count" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1 trailing\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end 1 1 1 trailing\nhello", n.block_end);
}

test "tmux block terminator requires numeric metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end foo bar baz\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end foo bar baz\nhello", n.block_end);
}

test "tmux output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %42 foo bar baz") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(42, n.output.pane_id);
    try testing.expectEqualStrings("foo bar baz", n.output.data);
}

test "tmux output preserves split multibyte UTF-8 across notifications" {
    // tmux emits one %output per pane read and does NOT align the boundary to
    // UTF-8 character boundaries, so a multibyte glyph is routinely split across
    // two consecutive notifications. The parser must return the EXACT raw bytes
    // (a UTF-8 regex drops or truncates the lone lead/continuation byte, which
    // surfaces downstream as a U+FFFD "diamond"). The persistent per-pane VT
    // decoder reassembles the glyph once it receives both halves intact.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // 'é' == 0xC3 0xA9. Lead byte arrives in the first notification...
    for ("%output %1 a\xC3") |byte| try testing.expect(try c.put(byte) == null);
    const n1 = (try c.put('\n')).?;
    try testing.expect(n1 == .output);
    try testing.expectEqual(1, n1.output.pane_id);
    try testing.expectEqualStrings("a\xC3", n1.output.data);

    // ...continuation byte in the second. Read n1.data above before feeding n2
    // (the next '%' clears the shared buffer that n1.data points into).
    for ("%output %1 \xA9b") |byte| try testing.expect(try c.put(byte) == null);
    const n2 = (try c.put('\n')).?;
    try testing.expect(n2 == .output);
    try testing.expectEqualStrings("\xA9b", n2.output.data);
}

test "tmux output preserves raw high bytes and octal escapes" {
    // tmux passes bytes >= 0x20 raw (incl. all UTF-8) and escapes only <0x20
    // and '\\' as \\ooo. The parser hands the payload through verbatim; octal
    // unescaping happens later in the viewer, so the escapes stay literal here.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // '─' (U+2500) == 0xE2 0x94 0x80 raw, followed by an escaped ESC (\033).
    for ("%output %7 \xE2\x94\x80\\033[0m") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(7, n.output.pane_id);
    try testing.expectEqualStrings("\xE2\x94\x80\\033[0m", n.output.data);
}

test "tmux session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-changed $42 foo") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_changed);
    try testing.expectEqual(42, n.session_changed.id);
    try testing.expectEqualStrings("foo", n.session_changed.name);
}

test "tmux sessions-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux sessions-changed carriage return" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux session-window-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-window-changed $1 @3") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_window_changed);
    try testing.expectEqual(1, n.session_window_changed.session_id);
    try testing.expectEqual(3, n.session_window_changed.window_id);
}

test "tmux session-window-changed carriage return" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-window-changed $1 @3\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_window_changed);
    try testing.expectEqual(1, n.session_window_changed.session_id);
    try testing.expectEqual(3, n.session_window_changed.window_id);
}

test "tmux layout-change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%layout-change @2 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} *-") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .layout_change);
    try testing.expectEqual(2, n.layout_change.window_id);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.layout);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.visible_layout);
    try testing.expectEqualStrings("*-", n.layout_change.raw_flags);
}

test "tmux window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-add @14") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_add);
    try testing.expectEqual(14, n.window_add.id);
}

test "tmux window-close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-close @7") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_close);
    try testing.expectEqual(7, n.window_close.id);
}

test "tmux window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-renamed @42 bar") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_renamed);
    try testing.expectEqual(42, n.window_renamed.id);
    try testing.expectEqualStrings("bar", n.window_renamed.name);
}

test "tmux window-pane-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-pane-changed @42 %2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_pane_changed);
    try testing.expectEqual(42, n.window_pane_changed.window_id);
    try testing.expectEqual(2, n.window_pane_changed.pane_id);
}

test "tmux client-detached" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-detached /dev/pts/1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_detached);
    try testing.expectEqualStrings("/dev/pts/1", n.client_detached.client);
}

test "tmux client-session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-session-changed /dev/pts/1 $2 mysession") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_session_changed);
    try testing.expectEqualStrings("/dev/pts/1", n.client_session_changed.client);
    try testing.expectEqual(2, n.client_session_changed.session_id);
    try testing.expectEqualStrings("mysession", n.client_session_changed.name);
}

test "tmux pane-mode-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%pane-mode-changed %5") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .pane_mode_changed);
    try testing.expectEqual(5, n.pane_mode_changed.pane_id);
}

test "tmux session-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-renamed my-session") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_renamed);
    try testing.expectEqualStrings("my-session", n.session_renamed.name);
}

test "tmux pause" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%pause %3") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .pause);
    try testing.expectEqual(3, n.pause.pane_id);
}

test "tmux continue" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%continue %3") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .@"continue");
    try testing.expectEqual(3, n.@"continue".pane_id);
}

test "tmux block begin/end mismatch still processes" {
    // Mismatched command_id between %begin and %end should log a warning
    // but still return the block_end notification (resilient processing).
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    // block_begin should be set after %begin
    try testing.expect(c.block_begin != null);
    try testing.expectEqual(269, c.block_begin.?.command_id);

    for ("some data\n") |byte| try testing.expect(try c.put(byte) == null);
    // Mismatched command_id (999 instead of 269)
    for ("%end 1578922740 999 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    // Block should still be processed despite mismatch
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("some data", n.block_end);
    // block_begin should be cleared
    try testing.expect(c.block_begin == null);
}

test "tmux block begin tokens parsed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 42 100 0\n") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(c.block_begin != null);
    try testing.expectEqual(42, c.block_begin.?.time);
    try testing.expectEqual(100, c.block_begin.?.command_id);
    try testing.expectEqual(0, c.block_begin.?.flags);

    for ("%end 42 100 0") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expect(c.block_begin == null);
}

test "tmux block begin malformed tokens" {
    // If %begin tokens can't be parsed, block_begin is null but
    // block processing still works (validation is skipped).
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // Malformed: non-numeric time
    for ("%begin abc 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(c.block_begin == null);
    // Block state should still be entered
    try testing.expect(c.state == .block);

    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
}

test "tmux exit notification" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%exit") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .exit);
}

test "tmux exit notification with reason" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // %exit can have an optional reason string which we drop
    for ("%exit server exited") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .exit);
}

test "tmux extended-output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%extended-output %5 1234 : hello\\033[m") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .extended_output);
    try testing.expectEqual(5, n.extended_output.pane_id);
    try testing.expectEqual(1234, n.extended_output.age_ms);
    try testing.expectEqualStrings("hello\\033[m", n.extended_output.data);
}

test "tmux extended-output preserves raw payload and embedded colon-space" {
    // The payload begins after the FIRST " : " that follows the age field, and
    // is passed through verbatim — including raw split-UTF-8 bytes and any
    // further ": " sequences that occur inside the data itself.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%extended-output %2 100 : foo: bar : baz\xC3") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .extended_output);
    try testing.expectEqual(2, n.extended_output.pane_id);
    try testing.expectEqual(100, n.extended_output.age_ms);
    try testing.expectEqualStrings("foo: bar : baz\xC3", n.extended_output.data);
}

test "tmux ignored notifications suppressed" {
    // Recognized-but-ignored notifications should not produce any
    // notification (null return) and should not log as "unknown".
    const testing = std.testing;
    const alloc = testing.allocator;

    const ignored_lines = [_][]const u8{
        "%unlinked-window-add @1",
        "%unlinked-window-close @2",
        "%unlinked-window-renamed @3 newname",
        "%paste-buffer-changed buf0",
        "%paste-buffer-deleted buf1",
        "%subscription-changed myvar $1 @2 3 %4 : value",
    };

    for (ignored_lines) |line| {
        var c: Parser = .{ .buffer = .init(alloc) };
        defer c.deinit();
        for (line) |byte| try testing.expect(try c.put(byte) == null);
        // Should return null (ignored), not a notification
        try testing.expect(try c.put('\n') == null);
        // Parser should return to idle, not broken
        try testing.expect(c.state == .idle);
    }
}

test "tmux message" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%message Session created session 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .message);
    try testing.expectEqualStrings("Session created session 1", n.message.text);
}
