//! This file contains the implementation for tmux control mode. See
//! tmux(1) for more information on control mode. Some basics are documented
//! here but this is not meant to be a comprehensive source of protocol
//! documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;

const log = std.log.scoped(.terminal_tmux);

/// The `refresh-client -B` subscription name the viewer uses to track each
/// window's active-pane title (`#{pane_title}`). `%subscription-changed`
/// notifications carrying this name deliver a window id plus the title value.
/// Shared with `viewer.zig`, which both issues the subscription command and
/// filters incoming notifications by this name.
pub const title_subscription_name = "ghostty_title";

/// Privacy-safe last-error code surfaced to the iOS debug snapshot
/// (`ghostty_surface_tmux_debug_snapshot`). Shared by the control `Parser` and
/// the `Viewer` so a single u8 in the snapshot can explain WHY the channel
/// broke or the viewer went defunct, without ever exposing the offending bytes.
/// FROZEN for the snapshot ABI: only append; never renumber. ROOTSHELL-TMUX
/// (id=control-error-code)
pub const ErrorCode = enum(u8) {
    none = 0,
    /// `.idle` saw a stray non-'%' byte and broke the channel.
    stray_byte_broken = 1,
    /// The control buffer exceeded `max_bytes`.
    buffer_overflow = 2,
    /// A `%begin`/`%end` token mismatch (logged, block still processed).
    block_mismatch = 3,
    /// tmux reported a command error (`%error` block).
    control_error = 4,
    /// The viewer received a block with no command in flight.
    unexpected_block = 5,
    /// The viewer went defunct for an unspecified reason.
    defunct = 6,
    /// The sent-FIFO could not grow (allocator exhaustion; may desync).
    sent_fifo_oom = 7,
    /// A resume resync failed to queue its rebuild.
    resync_rebuild_failed = 8,
    /// A recognized notification line was malformed; request live resync.
    malformed_notification = 9,
};

/// Parsed tokens from a %begin, %end, or %error guard line.
/// tmux guarantees these match between begin and end/error. Bit 0 of
/// `flags` is set for client-originated command responses and clear for
/// server-originated blocks.
pub const BlockInfo = struct {
    time: usize,
    command_id: usize,
    flags: usize,
};

/// A begin/end block plus the guard metadata that framed it.
pub const Block = struct {
    content: []const u8,
    info: BlockInfo,
};

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

    /// Resync-tolerant mode for a mid-stream control-mode RESUME (the iOS app
    /// reattached a live `tmux -CC`). The parser is created at an arbitrary
    /// point, so the leading bytes are a partial line / block content that the
    /// strict `.idle` "non-'%' => broken" rule would trip on. While tolerant,
    /// `.idle` SKIPS non-'%' bytes instead of breaking, so the parser harmlessly
    /// discards reattach garbage until it lands on a real notification. It is
    /// cleared the moment we complete a `%begin/%end` block (a definitive
    /// alignment signal — and the resume probe's response is always such a
    /// block), restoring the normal break-on-stray safety. ROOTSHELL-TMUX
    /// (id=control-resync-tolerant)
    tolerant: bool = false,

    /// Whether the current byte begins a line (the previous byte was '\n', or it
    /// is the first byte after `beginResync`). Updated every byte; only consulted
    /// while `tolerant`, where a notification may only start on a '%' at a line
    /// boundary — NOT a literal mid-line '%' from stale pane output, which would
    /// false-trigger a bogus notification. Set true by `beginResync` so the
    /// probe-first case (the gateway's idle answer is the very first byte) is
    /// accepted. ROOTSHELL-TMUX (id=control-resync-line-start)
    resync_at_line_start: bool = false,

    /// Most recent error this parser hit, surfaced to the iOS debug snapshot.
    /// Diagnostic only — sticky (last write wins); never reset. ROOTSHELL-TMUX
    /// (id=control-error-code)
    last_error: ErrorCode = .none,

    /// Edge-triggered request for the gateway to heal a framing desync by
    /// re-resyncing the LIVE control channel (NOT breaking it). Raised when the
    /// parser detects desync it cannot silently absorb — a stray byte in `.idle`
    /// (which used to break the channel → defunct → every tab torn down), a run
    /// of well-formed-but-mismatched block terminators, or a runaway block whose
    /// matching `%end` never arrives. All three are exactly what mid-stream data
    /// loss looks like (the tsshd buffer overflowing while the app is
    /// backgrounded drops a byte chunk, so the stream resumes mid-line/mid-block).
    /// The stream handler consumes this via `takeRecoverRequest` after each `put`
    /// and drives a live re-resync (re-probe + list-windows rebuild). The parser
    /// itself is left in resync-tolerant `.idle` (it does not break), so the
    /// channel survives even if the recover request races. ROOTSHELL-TMUX
    /// (id=control-recover-request)
    recover_pending: bool = false,

    /// Well-formed-but-mismatched block terminators seen since the current
    /// `%begin` (reset on block completion and on `beginResync`). tmux guarantees
    /// the `%end`/`%error` tuple matches its `%begin`, so a non-matching guard
    /// line is NOT this block's terminator: one is plausibly stray pane content
    /// shaped like a guard line, but several mean the real `%end` was lost and the
    /// block stream desynced — at which point we request recovery instead of
    /// merging blocks forever. ROOTSHELL-TMUX (id=control-block-mismatch-bound)
    mismatched_terminators: usize = 0,

    /// After this many well-formed-but-mismatched terminators within one block,
    /// the real `%end` is almost certainly lost (data loss merged the stream) —
    /// request a recovery resync rather than swallowing later blocks forever.
    /// ROOTSHELL-TMUX (id=control-block-mismatch-bound)
    const mismatched_terminator_limit = 4;

    /// Byte ceiling on a SINGLE block before requesting recovery. Comfortably
    /// above a legitimate `capture-pane -e -S -` history replay yet far below
    /// `max_bytes` (the broken/teardown cap), so a runaway/never-terminating
    /// block (a `%begin` whose `%end` was lost to data loss) self-heals via
    /// resync instead of breaking the channel. ROOTSHELL-TMUX
    /// (id=control-block-mismatch-bound)
    const block_recover_bytes = 16 * 1024 * 1024;

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
            self.last_error = .buffer_overflow; // ROOTSHELL-TMUX (id=control-error-code)
            self.broken();
            return error.OutOfMemory;
        }

        // Bound a runaway control-mode block (a `%begin` whose matching `%end`
        // was lost to mid-stream data loss) BELOW the hard broken/teardown cap,
        // so it self-heals via resync instead of breaking the channel. Checked
        // before any per-byte work and only while inside a block. ROOTSHELL-TMUX
        // (id=control-block-mismatch-bound)
        if (self.state == .block and self.buffer.written().len >= block_recover_bytes) {
            log.warn("tmux block exceeded {} bytes with no matching %end; requesting resync", .{block_recover_bytes});
            self.last_error = .block_mismatch; // ROOTSHELL-TMUX (id=control-error-code)
            self.requestRecover();
            return null;
        }

        // Track line boundaries for resync realignment (only consulted while
        // tolerant). `at_line_start` is whether THIS byte begins a line; update
        // the field for the NEXT byte. ROOTSHELL-TMUX (id=control-resync-line-start)
        const at_line_start = self.resync_at_line_start;
        self.resync_at_line_start = (byte == '\n');

        switch (self.state) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Waiting for a notification so if the byte is not '%' then
            // we're in a broken state. Control mode output should always
            // be wrapped in '%begin/%end' orelse we expect a notification.
            // Do not synthesize an exit notification here: a single leaked
            // terminal report or stray byte should stop this broken parser from
            // consuming more input, but it must not look like tmux intentionally
            // exited and force the UI to close every projected tab.
            .idle => if (byte == '\r' or byte == '\n') {
                // A bare CR or LF in idle is line-framing noise, NOT mid-stream
                // data loss: the PTY/SSH line discipline sprinkles CRs between
                // notifications, and a blank "\r\n" line can land here. Ignore it
                // (stay idle, start no notification) so it does not trip the
                // stray-byte self-heal below, which would otherwise false-fire a
                // resync on a perfectly healthy stream during heavy output. The
                // line discipline sprinkles CRs in wherever it likes; treat them
                // as nothing. ROOTSHELL-TMUX (id=control-strip-trailing-cr)
                return null;
            } else if (self.tolerant) {
                // Mid-stream RESUME: skip arbitrary reattach garbage instead of
                // breaking. Only start a notification on a '%' that begins a line
                // (byte 0 of the resync, or just after '\n') — NOT a literal
                // mid-line '%' in stale pane output, which would false-trigger a
                // bogus notification. ROOTSHELL-TMUX (id=control-resync-tolerant)
                if (byte == '%' and at_line_start) {
                    self.buffer.clearRetainingCapacity();
                    self.state = .notification;
                    // Fall through to buffer the leading '%'.
                } else {
                    self.buffer.clearRetainingCapacity();
                    return null;
                }
            } else if (byte != '%') {
                // A stray byte in `.idle` means the control-stream framing is
                // broken — overwhelmingly mid-stream data loss (the tsshd buffer
                // overflowed while the app was backgrounded, dropping a chunk so
                // the stream resumes mid-line). Do NOT break the channel: that
                // goes defunct and tears down every projected tab. Self-heal
                // instead — record the cause, enter resync-tolerant mode so the
                // rest of the garbage is skipped (not broken), and request a live
                // re-resync (re-probe + rebuild). We are mid-line, so do not treat
                // the next byte as a line start (wait for a real '\n%'); that also
                // preserves the "ignore mid-line %" guarantee. ROOTSHELL-TMUX
                // (id=control-recover-request)
                self.last_error = .stray_byte_broken; // ROOTSHELL-TMUX (id=control-error-code)
                self.requestRecover();
                return null;
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
                    // Only the guard line whose tuple MATCHES the `%begin`
                    // terminates the block. tmux guarantees the `%end`/`%error`
                    // tuple matches its `%begin`, so a well-formed but NON-matching
                    // guard line is NOT this block's real terminator: it is either
                    // stray pane content shaped like a guard line (e.g. a pane
                    // showing tmux logs — treat as body), or evidence that the real
                    // `%end` was lost to mid-stream data loss. Accepting it anyway
                    // is what merges two tmux blocks into one and desyncs the
                    // command/response FIFO (the observed hang). When the `%begin`
                    // could not be parsed (block_begin == null) we cannot validate,
                    // so we accept to make progress (prior behavior). ROOTSHELL-TMUX
                    // (id=control-block-mismatch-bound)
                    const matches = if (self.block_begin) |begin|
                        begin.time == result.info.time and
                            begin.command_id == result.info.command_id and
                            begin.flags == result.info.flags
                    else
                        true;

                    if (matches) {
                        self.block_begin = null;
                        self.mismatched_terminators = 0;

                        const output = std.mem.trimRight(
                            u8,
                            written[0..idx],
                            "\r\n",
                        );

                        // Important: do not clear buffer since the notification
                        // contains it.
                        self.state = .idle;
                        // Completing a block is a definitive alignment signal: leave
                        // resync-tolerant mode so the normal break-on-stray safety is
                        // restored. The resume probe's response is always a block.
                        // ROOTSHELL-TMUX (id=control-resync-tolerant)
                        self.tolerant = false;
                        // NOTE: we deliberately do NOT swallow server-originated blocks
                        // (begin/end flags bit 0 clear) at the parser. The STARTUP attach
                        // block (`tmux -CC new`/attach) is itself server-originated
                        // (flags=0 — it is not a control-channel command, so it lacks
                        // CMDQ_STATE_CONTROL), and the viewer's startup handshake needs
                        // it. Swallowing flags=0 here breaks attach entirely (no windows,
                        // stuck queue, ESC can't detach). The FIFO-desync that
                        // server-originated steady-state blocks could cause must instead
                        // be handled at the consumer (gated on viewer state / matched to
                        // sent commands), not by dropping the block. See
                        // id=server-originated-block.
                        switch (result.terminator) {
                            .end => return .{ .block_end = .{
                                .content = output,
                                .info = result.info,
                            } },
                            .err => {
                                self.last_error = .control_error; // ROOTSHELL-TMUX (id=control-error-code)
                                log.warn("tmux control mode error={s}", .{output});
                                return .{ .block_err = .{
                                    .content = output,
                                    .info = result.info,
                                } };
                            },
                        }
                    }

                    // Well-formed but non-matching terminator: treat it as block
                    // body (fall through to accumulate). Count it — several within
                    // one block mean the real `%end` was lost and the block stream
                    // desynced, so request a recovery resync rather than merging
                    // blocks forever. ROOTSHELL-TMUX (id=control-block-mismatch-bound)
                    self.last_error = .block_mismatch; // ROOTSHELL-TMUX (id=control-error-code)
                    self.mismatched_terminators += 1;
                    if (self.mismatched_terminators >= mismatched_terminator_limit) {
                        log.warn(
                            "tmux block desync ({} mismatched terminators); requesting resync",
                            .{self.mismatched_terminators},
                        );
                        self.requestRecover();
                        return null;
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
    ///
    /// While resync-tolerant (mid-stream RESUME, not yet realigned) we are in
    /// `.idle` but must NOT terminate on a stray ST in the reattach garbage —
    /// that ST is not tmux's real closing ST. ROOTSHELL-TMUX
    /// (id=control-resync-tolerant)
    pub fn canTerminate(self: *const Parser) bool {
        return (self.state == .idle and !self.tolerant) or self.state == .broken;
    }

    /// Enter resync-tolerant mode for a mid-stream control-mode RESUME (the iOS
    /// app reattached a live `tmux -CC`). The parser stays in `.idle` but skips
    /// arbitrary reattach garbage instead of breaking, until it lands on a real
    /// notification and completes a block (which clears tolerance). Called right
    /// after the synthetic control-mode entry on resume. ROOTSHELL-TMUX
    /// (id=control-resync-tolerant)
    pub fn beginResync(self: *Parser) void {
        self.state = .idle;
        self.tolerant = true;
        // Treat the first post-resync byte as a line start so the probe-first
        // case (an idle gateway's answer is literally byte 0) is accepted.
        self.resync_at_line_start = true;
        // Drop any in-progress block framing: a resync realigns to a fresh
        // notification, so a stale `%begin`/mismatch count must not leak across.
        // ROOTSHELL-TMUX (id=control-block-mismatch-bound)
        self.block_begin = null;
        self.mismatched_terminators = 0;
        self.buffer.clearRetainingCapacity();
    }

    /// Self-heal a framing desync without breaking the channel: enter
    /// resync-tolerant `.idle` (so the remaining mid-stream garbage is skipped,
    /// not broken) and raise the recover edge for the stream handler to drive a
    /// live re-resync. Unlike `beginResync` (a fresh RESUME, where byte 0 is the
    /// probe answer), we are mid-line here, so the next byte is NOT a line start —
    /// wait for a real '\n%' before starting a notification, preserving the
    /// "ignore mid-line %" guarantee. ROOTSHELL-TMUX (id=control-recover-request)
    fn requestRecover(self: *Parser) void {
        self.beginResync();
        self.resync_at_line_start = false;
        self.recover_pending = true;
    }

    /// Take-and-clear the recovery-request edge (see `recover_pending`). The
    /// stream handler calls this after feeding each byte; a true result means it
    /// should drive a live re-resync of the gateway. ROOTSHELL-TMUX
    /// (id=control-recover-request)
    pub fn takeRecoverRequest(self: *Parser) bool {
        const v = self.recover_pending;
        self.recover_pending = false;
        return v;
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
        // Tokenize on spaces AND carriage returns. The SSH/PTY line discipline
        // sprinkles CRs anywhere on a control line — a trailing "\r\r\n", or even
        // mid-line — and tmux escapes every real control byte as \ooo, so a raw
        // CR in a guard line is always framing noise, never data. Treating CR as
        // a delimiter (like a space) drops it wherever it lands, which is
        // symmetric with parseNotification's strip-all-trailing-CR.
        // Without this, a CR-mangled %end (e.g. "%end 1 1 1\r\r") fails to parse,
        // the block never closes, later blocks merge into it, and the
        // command/response sent-FIFO desyncs — the control-mode wedge that forces
        // a resync/force-exit. ROOTSHELL-TMUX (id=control-strip-trailing-cr)
        var fields = std.mem.tokenizeAny(u8, line_raw, " \r");
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
        // CR-tolerant tokenization, for the same reason as parseBlockTerminator:
        // ignore any CRs the line driver injected into the guard line so a
        // CR-mangled %begin still opens its block (kept symmetric with %end).
        // ROOTSHELL-TMUX (id=control-strip-trailing-cr)
        var fields = std.mem.tokenizeAny(u8, line, " \r");
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

    fn isRecoverableKnownNotification(cmd: []const u8) bool {
        const recoverable = [_][]const u8{
            "%output",
            "%session-changed",
            "%sessions-changed",
            "%session-window-changed",
            "%layout-change",
            "%window-add",
            "%window-close",
            "%window-renamed",
            "%window-pane-changed",
            "%client-detached",
            "%client-session-changed",
            "%pane-mode-changed",
            "%session-renamed",
            "%pause",
            "%continue",
            "%extended-output",
            "%message",
            "%subscription-changed",
        };

        for (recoverable) |known| {
            if (std.mem.eql(u8, cmd, known)) return true;
        }

        return false;
    }

    fn parseNotification(self: *Parser) ParseError!?Notification {
        assert(self.state == .notification);

        const line = line: {
            var line = self.buffer.written();
            // Strip ALL trailing CRs, not just one. The control stream reaches
            // us over a PTY/SSH channel whose ONLCR line discipline turns tmux's
            // "\n" terminator into "\r\n" — and for some lines into "\r\r\n"
            // (observed on %output/%extended-output chunks split mid-escape).
            // tmux escapes every real control byte, CR included, as \ooo
            // (control.c control_append_data), so a literal 0x0d in a control
            // line is always framing noise, never pane payload. Dropping just
            // one CR leaves the second as the payload's last byte; fed into the
            // pane VT stream it snaps the cursor to column 0 and the next write
            // lands in the gutter (the helix scroll corruption).
            // ROOTSHELL-TMUX (id=control-strip-trailing-cr)
            while (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
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
            // Format: %session-renamed $<id> <name>
            // tmux emits a leading `$<id>` (control-notify.c
            // control_notify_session_renamed: "%%session-renamed $%u %s"); the
            // man page's older `<name>`-only form is stale. Strip the id like
            // %session-changed does, otherwise the id leaks into the title.
            const after = afterCmd(line, cmd) orelse break :cmd;
            const id = parseSigilInt(after, '$') orelse break :cmd;
            const name = afterSpace(id.rest) orelse break :cmd;

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_renamed = .{ .name = name } };
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
            // The tmux server is exiting or has detached. tmux may append an
            // optional reason ("%exit <reason>", e.g. "server exited", "killed").
            // We can't carry it in the (void) exit notification without reworking
            // the DCS/teardown path, but LOG it (a clean detach has no reason) so a
            // session whose tmux tabs suddenly vanished is diagnosable instead of
            // silently torn down. The reason is a short tmux status string, not user
            // content. ROOTSHELL-TMUX (id=exit-reason-log)
            if (afterCmd(line, cmd)) |reason| {
                if (reason.len > 0) log.info("tmux control mode %exit reason: {s}", .{reason});
            }
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
        } else if (std.mem.eql(u8, cmd, "%subscription-changed")) cmd: {
            // Format (per tmux control.c control_check_subs_*; the header
            // shape varies by subscription type but always ends " : <value>"):
            //   all-windows (@*): %subscription-changed <name> $<sid> @<wid> <idx> - : <value>
            //   all-panes   (%*): %subscription-changed <name> $<sid> @<wid> <idx> %<pid> : <value>
            // Parse defensively: the value is everything after the FIRST
            // " : " (a pane title may itself contain " : "); the window id is
            // the @<n> header token; the name is the first header token.
            // Keying off the @ sigil instead of a fixed field position keeps
            // this robust across tmux's per-type header shapes. Subscriptions
            // without a window id (session scope) are not parsed — we don't
            // create them.
            const after = afterCmd(line, cmd) orelse break :cmd;
            const delim = std.mem.indexOf(u8, after, " : ") orelse break :cmd;
            const header = after[0..delim];
            const value = after[delim + 3 ..];

            const name_field = nextField(header);
            if (name_field.token.len == 0) break :cmd;

            // Find the @<window-id> token among the remaining header fields.
            var fields = std.mem.tokenizeScalar(u8, name_field.rest, ' ');
            const window_id: usize = while (fields.next()) |tok| {
                if (parseSigilInt(tok, '@')) |wid| {
                    if (wid.rest.len == 0) break wid.value;
                }
            } else break :cmd;

            // Important: do not clear buffer here since name/value point to it.
            self.state = .idle;
            return .{ .subscription_changed = .{
                .name = name_field.token,
                .window_id = window_id,
                .value = value,
            } };
        } else if (std.mem.eql(u8, cmd, "%unlinked-window-add") or
            std.mem.eql(u8, cmd, "%unlinked-window-close") or
            std.mem.eql(u8, cmd, "%unlinked-window-renamed") or
            std.mem.eql(u8, cmd, "%paste-buffer-changed") or
            std.mem.eql(u8, cmd, "%paste-buffer-deleted") or
            std.mem.eql(u8, cmd, "%config-error"))
        {
            // Recognized but intentionally ignored notifications. These relate
            // to other sessions' windows, clipboard buffers, or config-file parse
            // errors (`%config-error`) that don't affect topology. Listed here so
            // they don't trip the "unknown notification" warning below.
            log.debug("ignoring tmux notification: {s}", .{cmd});
        } else {
            // Unknown notification, log it and return to idle state.
            log.warn("unknown tmux control mode notification={s}", .{cmd});
        }

        if (self.state == .notification and isRecoverableKnownNotification(cmd)) {
            // A recognized notification whose fields no longer match tmux's
            // grammar is strong evidence that we started parsing mid-line
            // or lost bytes. Treat it like other framing damage: enter
            // tolerant resync mode and let the stream handler probe/rebuild
            // instead of silently returning to idle with partially corrupt
            // topology or pane state.
            log.warn("malformed tmux control mode notification={s}", .{cmd});
            self.last_error = .malformed_notification;
            self.requestRecover();
            return null;
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

    /// The control stream became malformed. This is distinct from `%exit`:
    /// callers should stop the DCS parser so the gateway terminal can recover,
    /// but should not treat it as an intentional tmux detach/exit event.
    broken,

    /// Dispatched at the end of a begin/end block with the raw data and guard
    /// metadata.
    /// The control mode parser can't parse the data because it is unaware
    /// of the command that was sent to trigger this output.
    block_end: Block,
    block_err: Block,

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

    /// A subscribed format value changed (`refresh-client -B`). tmux sends
    /// these on a ~1s timer, only when the value actually changed. We
    /// subscribe to `@*:#{pane_title}` (all windows), so `window_id`
    /// identifies the window and `value` is that window's active-pane title
    /// (`#T`). Slice fields point into the parser buffer and are valid only
    /// until the next `next()`.
    subscription_changed: struct {
        /// Subscription name (the first header field). The caller matches
        /// this against the name it subscribed with
        /// (`title_subscription_name`).
        name: []const u8,
        window_id: usize,
        value: []const u8,
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
    try testing.expectEqualStrings("", n.block_end.content);
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
    try testing.expectEqualStrings("", n.block_err.content);
}

test "tmux flags=0 (server-originated) block is delivered, not swallowed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // A flags=0 block is server-originated. Critically, the STARTUP attach block
    // (`tmux -CC new` / attach) is itself flags=0 (it is not a control-channel
    // command, so it lacks CMDQ_STATE_CONTROL). It MUST be delivered, or the
    // viewer's startup handshake never completes (no windows, stuck queue, ESC
    // can't detach). ROOTSHELL-TMUX (id=server-originated-block)
    for ("%begin 1 5 0\nhook output\n%end 1 5 0") |byte| {
        try testing.expect(try c.put(byte) == null);
    }
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hook output", n.block_end.content);
    try testing.expectEqual(@as(usize, 1), n.block_end.info.time);
    try testing.expectEqual(@as(usize, 5), n.block_end.info.command_id);
    try testing.expectEqual(@as(usize, 0), n.block_end.info.flags);
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
    try testing.expectEqualStrings("hello\nworld", n.block_end.content);
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
    try testing.expectEqualStrings("%end not really\nhello", n.block_end.content);
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
    try testing.expectEqualStrings("%error not really\nhello", n.block_end.content);
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
    try testing.expectEqualStrings("%error not really\nhello", n.block_err.content);
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
    try testing.expectEqualStrings("%end 1 1 1 trailing\nhello", n.block_end.content);
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
    try testing.expectEqualStrings("%end foo bar baz\nhello", n.block_end.content);
}

test "tmux block terminator tolerates \\r\\r\\n framing (wedge regression)" {
    // ROOTSHELL-TMUX (id=control-strip-trailing-cr): the SSH/PTY line discipline
    // sprinkles extra CRs onto ANY control line, including a block's %end guard
    // line ("\r\r\n" framing). parseNotification strips all trailing CRs for
    // %begin, but parseBlockTerminator must do the same — otherwise the %end is
    // mis-read as block body, the block never closes, later blocks merge into it,
    // and the command/response sent-FIFO desyncs (the control-mode wedge that
    // forces a resync/force-exit). A few scrolls' worth of output is enough to
    // hit one CR-mangled %end. This test is the proof: it FAILS before the fix.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // Both the %begin and %end guard lines carry the doubled-CR framing.
    for ("%begin 1 1 1\r\r\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1\r\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello", n.block_end.content);
    // The block closed cleanly: no desync, no recovery edge raised.
    try testing.expect(!c.recover_pending);
    try testing.expect(c.state == .idle);
}

test "tmux block terminator tolerates a CR injected mid guard line" {
    // ROOTSHELL-TMUX (id=control-strip-trailing-cr): a CR can land anywhere on a
    // line, not just at the end. A CR inside the %end tuple must not stop the
    // block from terminating.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 7 8 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hi\n") |byte| try testing.expect(try c.put(byte) == null);
    // CR between the second and third tuple fields.
    for ("%end 7 8\r 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hi", n.block_end.content);
    try testing.expect(!c.recover_pending);
}

test "tmux idle ignores bare CR/LF framing without self-healing" {
    // ROOTSHELL-TMUX (id=control-strip-trailing-cr): a bare CR or LF arriving in
    // .idle (a blank "\r\n" line, or an extra CR the line driver appended after a
    // terminator) is framing noise, NOT mid-stream data loss. It must not trip
    // the stray-byte self-heal, which would false-fire a resync on a perfectly
    // healthy stream.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // A blank CRLF line at the top level.
    for ("\r\n") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(c.state == .idle);
    try testing.expect(!c.tolerant);
    try testing.expect(!c.recover_pending);
    try testing.expect(c.last_error == .none);
    // A normal notification right after still parses.
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
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

test "tmux malformed known notification requests recovery" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output not-a-pane payload") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(try c.put('\n') == null);
    try testing.expect(c.recover_pending);
    try testing.expect(c.tolerant);
    try testing.expect(c.state == .idle);
    try testing.expect(c.last_error == .malformed_notification);
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
    // tmux emits a leading `$<id>` which must be stripped from the title.
    for ("%session-renamed $3 my-session") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_renamed);
    try testing.expectEqualStrings("my-session", n.session_renamed.name);
}

test "tmux subscription-changed all-windows form" {
    // all-windows (@*) header: <name> $<sid> @<wid> <idx> - : <value>
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%subscription-changed ghostty_title $1 @7 3 - : my pane title") |byte|
        try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .subscription_changed);
    try testing.expectEqualStrings("ghostty_title", n.subscription_changed.name);
    try testing.expectEqual(7, n.subscription_changed.window_id);
    try testing.expectEqualStrings("my pane title", n.subscription_changed.value);
}

test "tmux subscription-changed all-panes form with pane id" {
    // all-panes (%*) header: <name> $<sid> @<wid> <idx> %<pid> : <value>
    // We still key off the @<wid> token and ignore the pane id.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%subscription-changed ghostty_title $1 @2 3 %4 : value") |byte|
        try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .subscription_changed);
    try testing.expectEqual(2, n.subscription_changed.window_id);
    try testing.expectEqualStrings("value", n.subscription_changed.value);
}

test "tmux subscription-changed value containing colon-space" {
    // The value is everything after the FIRST " : "; a value that itself
    // contains " : " must be preserved verbatim.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%subscription-changed ghostty_title $1 @9 1 - : foo : bar") |byte|
        try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .subscription_changed);
    try testing.expectEqual(9, n.subscription_changed.window_id);
    try testing.expectEqualStrings("foo : bar", n.subscription_changed.value);
}

test "tmux subscription-changed empty value" {
    // A pane with no title yields an empty value after " : ".
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%subscription-changed ghostty_title $1 @5 1 - : ") |byte|
        try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .subscription_changed);
    try testing.expectEqual(5, n.subscription_changed.window_id);
    try testing.expectEqualStrings("", n.subscription_changed.value);
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

test "tmux block begin/end mismatch is treated as body, real %end terminates" {
    // A well-formed %end whose tuple does NOT match the open %begin is NOT this
    // block's terminator (tmux guarantees they match): accepting it merges two
    // blocks and desyncs the command/response FIFO (the observed hang). It must
    // be treated as body so the real matching %end ends the block. ROOTSHELL-TMUX
    // (id=control-block-mismatch-bound)
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    // block_begin should be set after %begin
    try testing.expect(c.block_begin != null);
    try testing.expectEqual(269, c.block_begin.?.command_id);

    for ("some data\n") |byte| try testing.expect(try c.put(byte) == null);
    // Mismatched command_id (999 instead of 269): does NOT terminate the block.
    for ("%end 1578922740 999 1\n") |byte| try testing.expect(try c.put(byte) == null);
    // A single mismatch is absorbed as body, not escalated to recovery.
    try testing.expect(!c.recover_pending);
    try testing.expect(c.block_begin != null);

    // The real matching %end ends the block; the stray line is part of the body.
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("some data\n%end 1578922740 999 1", n.block_end.content);
    // block_begin should be cleared after the real terminator.
    try testing.expect(c.block_begin == null);
}

test "tmux block begin tokens parsed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // flags=1 (control-client originated): a flags=0 block is server-originated
    // and is swallowed (id=server-originated-block), so use 1 here to exercise the
    // begin-token parsing AND get a block_end.
    for ("%begin 42 100 1\n") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(c.block_begin != null);
    try testing.expectEqual(42, c.block_begin.?.time);
    try testing.expectEqual(100, c.block_begin.?.command_id);
    try testing.expectEqual(1, c.block_begin.?.flags);

    for ("%end 42 100 1") |byte| try testing.expect(try c.put(byte) == null);
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
    // %exit can have an optional reason string. It is logged (id=exit-reason-log),
    // not carried in the notification, so the parse result is still a bare .exit.
    for ("%exit server exited") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .exit);
}

test "tmux idle stray byte self-heals into resync (no synthetic exit, no break)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // A stray byte in idle (mid-stream data loss) must NOT break the channel
    // (that goes defunct → tabs torn down) and must NOT synthesize an exit.
    // Instead it self-heals: stays alive in resync-tolerant idle and raises the
    // recover edge for the stream handler to drive a live re-resync.
    try testing.expect(try c.put(0x1b) == null);
    try testing.expect(c.state == .idle);
    try testing.expect(c.tolerant);
    try testing.expect(c.last_error == .stray_byte_broken);
    try testing.expect(c.takeRecoverRequest());
    // Edge is take-and-clear.
    try testing.expect(!c.takeRecoverRequest());

    // Remaining mid-line garbage is skipped (tolerant), not broken, and never
    // becomes an exit. A literal mid-line `%` is ignored until a real line start.
    for ("[c%exit") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(c.state != .broken);

    // A clean notification at a real line start realigns and parses normally.
    for ("\n%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux well-formed non-matching terminator is body, real %end terminates" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // A well-formed `%end` whose tuple does NOT match the open `%begin` is stray
    // pane content, NOT this block's terminator: it must be treated as body so
    // the real matching `%end` ends the block (prevents the block-merge desync).
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 2 2 2\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end 2 2 2\nhello", n.block_end.content);
    // A single non-matching terminator is absorbed, not escalated to recovery.
    try testing.expect(!c.recover_pending);
}

test "tmux repeated mismatched terminators request recovery (lost %end)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Mid-stream data loss can drop a real `%end`, so subsequent blocks' `%end`
    // lines all mismatch the still-open `%begin`. After the limit we must stop
    // merging and request a resync — without breaking the channel.
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    var i: usize = 0;
    while (i < Parser.mismatched_terminator_limit) : (i += 1) {
        for ("%end 9 9 9\n") |byte| try testing.expect(try c.put(byte) == null);
    }
    try testing.expect(c.takeRecoverRequest());
    try testing.expect(c.state == .idle);
    try testing.expect(c.tolerant);
    try testing.expect(c.state != .broken);
}

test "tmux resync parses the probe block when it is the FIRST thing seen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // The critical idle-session case: on RESUME the gateway is at a shell prompt,
    // so tmux sends nothing until it answers OUR probe — the probe response block
    // is literally the first thing the (freshly resynced) parser sees. It must
    // NOT be discarded.
    c.beginResync();
    try testing.expect(c.tolerant);
    // flags=1: the probe is a control-client display-message command (a flags=0
    // block would be server-originated and swallowed; id=server-originated-block).
    for ("%begin 1 2 1\n__ROOTSHELL_TMUX_RESYNC__ $1\n%end 1 2 1") |byte| {
        try testing.expect(try c.put(byte) == null);
        try testing.expect(c.state != .broken);
    }
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expect(std.mem.indexOf(u8, n.block_end.content, "__ROOTSHELL_TMUX_RESYNC__") != null);
    // Completing a block clears tolerance (alignment restored).
    try testing.expect(!c.tolerant);
    try testing.expect(c.state == .idle);
}

test "tmux resync skips mid-line/mid-block garbage without breaking" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // A mid-stream RESUME landing inside a line / block: arbitrary leading bytes
    // are skipped (not broken) until a real block parses.
    c.beginResync();
    for ("rbage from mid-line\nsome content line\n\n") |byte| {
        try testing.expect(try c.put(byte) == null);
        try testing.expect(c.state != .broken);
    }
    // flags=1: a client command response (flags=0 would be swallowed as
    // server-originated; id=server-originated-block).
    for ("%begin 3 4 1\nhi\n%end 3 4 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expect(!c.tolerant);
    try testing.expect(c.state == .idle);
}

test "tmux resync ignores a literal mid-line % in reattach garbage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    c.beginResync();
    // A partial line containing a literal '%' that is NOT at a line start must
    // not falsely start a notification — it is skipped until a real line-start
    // '%'. Guards against latching onto stale pane output that contains '%'.
    for ("output with a % sign mid-line\n") |byte| {
        try testing.expect(try c.put(byte) == null);
        try testing.expect(c.state != .broken);
        try testing.expect(c.state != .notification); // never falsely entered
    }
    // The real block at a true line start then parses.
    // flags=1: a client command response (flags=0 would be swallowed as
    // server-originated; id=server-originated-block).
    for ("%begin 1 2 1\nhi\n%end 1 2 1") |byte| _ = try c.put(byte);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expect(!c.tolerant);
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

test "tmux extended-output strips a stray trailing CR (\\r\\r\\n framing)" {
    // The control stream arrives over a PTY/SSH channel whose ONLCR discipline
    // can turn tmux's "\n" terminator into "\r\r\n" for some payload lines. We
    // split on '\n', so the line still carries TWO trailing CRs. Only one is
    // the normal CRLF; the second would otherwise become the payload's last
    // byte and snap the pane cursor to column 0 (gutter/whole-line corruption
    // when scrolling). All trailing CRs must be stripped.
    // ROOTSHELL-TMUX (id=control-strip-trailing-cr)
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // payload "...234;" followed by a stray CR + the CRLF terminator's CR
    // (the observed "\r\r\n" framing; one CR would be handled by older code,
    // so the regression specifically needs two).
    for ("%extended-output %1 896 : \\033[38;2;199;146;234;\r\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .extended_output);
    try testing.expectEqual(1, n.extended_output.pane_id);
    // No trailing CR may survive into the pane payload.
    try testing.expectEqualStrings("\\033[38;2;199;146;234;", n.extended_output.data);
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
