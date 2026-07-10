// ROOTSHELL-TMUX: this upstream-shared file carries fork-owned tmux control-mode
// hooks (DCS `ESC P 1000 p` enter detection, 7-bit/8-bit ST termination guarding
// for tmux blocks). All are gated behind `build_options.tmux_control_mode`. Grep
// "ROOTSHELL-TMUX" here for every hook. See docs/tmux-control-mode-fork.md.

const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const terminal = @import("main.zig");
const DCS = terminal.DCS;

const log = std.log.scoped(.terminal_dcs);

/// DCS command handler. This should be hooked into a terminal.Stream handler.
/// The hook/put/unhook functions are meant to be called from the
/// terminal.stream dcsHook, dcsPut, and dcsUnhook functions, respectively.
pub const Handler = struct {
    state: State = .{ .inactive = {} },

    /// Maximum bytes any DCS command can take. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    /// This is arbitrarily set to 1MB today, increase if needed.
    max_bytes: usize = 1024 * 1024,

    /// Tracks whether we received an ESC byte that could be the start
    /// of a 7-bit ST (ESC \). Because ESC is now forwarded as .put in
    /// dcs_passthrough (to prevent premature DCS termination from ESC
    /// bytes embedded in tmux control mode output), we must detect
    /// 7-bit ST ourselves.
    pending_esc: bool = false,

    pub fn deinit(self: *Handler) void {
        self.discard();
    }

    pub fn hook(self: *Handler, alloc: Allocator, dcs: DCS) ?Command {
        assert(self.state == .inactive);

        // Initialize our state to ignore in case of error
        self.state = .ignore;
        self.pending_esc = false;

        // Try to parse the hook.
        const hk_ = self.tryHook(alloc, dcs) catch |err| {
            log.info("error initializing DCS hook, will ignore hook err={}", .{err});
            return null;
        };
        const hk = hk_ orelse {
            log.info("unknown DCS hook: {}", .{dcs});
            return null;
        };

        self.state = hk.state;
        return hk.command;
    }

    const Hook = struct {
        state: State,
        command: ?Command = null,
    };

    fn tryHook(self: Handler, alloc: Allocator, dcs: DCS) !?Hook {
        // ROOTSHELL-TMUX (id=dcs-tmux-max-bytes): self's only previous use was
        // handing its 1 MiB cap to the tmux parser, which broke legitimate
        // >1 MiB capture replies. Kept as a parameter for upstream-diff shape.
        _ = self;
        return switch (dcs.intermediates.len) {
            0 => switch (dcs.final) {
                // Tmux control mode
                'p' => tmux: { // ROOTSHELL-TMUX (id=dcs-tmux-enter): ESC P 1000 p control-mode entry; further tmux hooks in this file are gated by build_options.tmux_control_mode
                    if (comptime !build_options.tmux_control_mode) {
                        log.debug("tmux control mode not enabled in build, ignoring", .{});
                        break :tmux null;
                    }

                    // Tmux control mode must start with ESC P 1000 p
                    if (dcs.params.len != 1 or dcs.params[0] != 1000) break :tmux null;

                    break :tmux .{
                        .state = .{
                            .tmux = .{
                                // ROOTSHELL-TMUX (id=dcs-tmux-max-bytes): do NOT
                                // inherit the handler's 1 MiB anti-malicious-DCS
                                // cap. tmux control mode is a long-lived line
                                // protocol whose single capture-pane reply blocks
                                // legitimately exceed 1 MiB (a 10k-line CJK
                                // history replay is ~1-3 MiB); inheriting the cap
                                // broke the parser at EXACTLY 1 MiB mid-reply and
                                // (via the old forwardPut error path) silently ate
                                // the rest of the channel — the "attach opens tabs
                                // but every pane is frozen/blank" wedge. The
                                // control parser has its own defenses: a 16 MiB
                                // per-block recover bound and a 64 MiB hard cap
                                // (its field default, used here).
                                .buffer = try .initCapacity(
                                    alloc,
                                    128, // Arbitrary choice to limit initial reallocs
                                ),
                            },
                        },
                        .command = .{ .tmux = .enter },
                    };
                },

                else => null,
            },

            1 => switch (dcs.intermediates[0]) {
                '+' => switch (dcs.final) {
                    // XTGETTCAP
                    // https://github.com/mitchellh/ghostty/issues/517
                    'q' => .{
                        .state = .{
                            .xtgettcap = try .initCapacity(
                                alloc,
                                128, // Arbitrary choice
                            ),
                        },
                    },

                    else => null,
                },

                '$' => switch (dcs.final) {
                    // DECRQSS
                    'q' => .{ .state = .{
                        .decrqss = .{},
                    } },

                    else => null,
                },

                else => null,
            },

            else => null,
        };
    }

    /// Put a byte into the DCS handler. This will return a command
    /// if a command needs to be executed.
    pub fn put(self: *Handler, byte: u8) ?Command {
        // CAN (0x18) / SUB (0x1A): ECMA-48 abort of a control string. The fork's
        // parse table forwards them as .put (so a raw byte inside a tmux payload
        // can't cut control mode short), so we honor the abort here instead. For
        // an ordinary DCS, discard and return to .inactive — the stream then
        // returns the parser to ground (see `isInactive`), otherwise the parser
        // would wedge in dcs_passthrough until an ST arrives. For the live tmux
        // control parser, forward them as content: control mode only ends via its
        // own %exit / .broken, never a stray byte. ROOTSHELL-TMUX
        // (id=dcs-can-sub-abort)
        if (byte == 0x18 or byte == 0x1A) {
            switch (self.state) {
                .tmux => if (comptime build_options.tmux_control_mode) {
                    // Forward as content (control mode only ends via %exit /
                    // .broken). Flush any pending ESC FIRST: an `ESC CAN` / `ESC
                    // SUB` embedded in the payload must keep BOTH bytes — clearing
                    // pending_esc and forwarding only CAN/SUB would silently drop
                    // the ESC the parser is deliberately preserving for tmux.
                    if (self.pending_esc) {
                        self.pending_esc = false;
                        if (self.forwardPut(0x1B)) |cmd| return cmd;
                    }
                    return self.forwardPut(byte);
                },
                else => {},
            }
            // Ordinary DCS: abort the control string to ground (discard without
            // dispatching). Dropping any buffered ESC is correct here — the whole
            // aborted string is discarded.
            self.discard();
            return null;
        }

        // Handle 7-bit ST detection. Because ESC (0x1B) is now forwarded
        // as .put in dcs_passthrough (rather than triggering a state
        // transition to .escape), we must detect the ESC + '\' sequence
        // that forms 7-bit ST ourselves.
        if (self.pending_esc) {
            self.pending_esc = false;
            if (byte == 0x5C) {
                // ESC \ = 7-bit ST. Normally this terminates the DCS. But tmux
                // control mode command-response content (e.g. an OSC string
                // terminator embedded in a `capture-pane -e` history replay on
                // attach) legitimately contains ESC \, and treating that as the
                // terminator ends control mode mid-stream — leaking the rest of
                // the protocol into the terminal. Only honor ESC \ as the
                // terminator when the tmux control parser is between
                // notifications (idle/broken), i.e. tmux's real closing ST after
                // a %exit line. Otherwise forward it as content.
                const terminate = switch (self.state) {
                    .tmux => |*tmux| if (comptime build_options.tmux_control_mode)
                        tmux.canTerminate()
                    else
                        true,
                    else => true,
                };
                if (terminate) return self.unhook();

                // Embedded content ST: forward the stored ESC then the '\'.
                if (self.forwardPut(0x1B)) |cmd| return cmd;
                return self.forwardPut(byte);
            }

            // Not ST. Forward the stored ESC to the sub-handler. If the current
            // byte is ANOTHER ESC, re-arm pending_esc so a following '\' is still
            // recognized as ST — `ESC ESC \` must terminate — instead of forwarding
            // the second ESC as content and losing the terminator. Mirrors
            // stream_terminal.zig's dcsDetectSt. ROOTSHELL-TMUX (id=dcs-pending-esc-rearm)
            if (byte == 0x1B) {
                self.pending_esc = true;
                return self.forwardPut(0x1B);
            }
            // Otherwise forward the stored ESC then the current byte as content.
            if (self.forwardPut(0x1B)) |cmd| return cmd;
            return self.forwardPut(byte);
        }

        if (byte == 0x1B) {
            self.pending_esc = true;
            return null;
        }

        // 8-bit C1 ST (0x9C). Same situation as 7-bit ESC \ above: it normally
        // terminates the DCS, but the parse table forwards it as .put because in
        // tmux control mode 0x9C is a valid UTF-8 continuation byte (e.g. 'Ü' =
        // 0xC3 0x9C) that appears throughout command-response content. Only
        // honor it as the terminator when the tmux control parser is between
        // notifications (idle/broken); otherwise it's content. Non-tmux DCS
        // states terminate on it as usual.
        if (byte == 0x9C) {
            const terminate = switch (self.state) {
                .tmux => |*tmux| if (comptime build_options.tmux_control_mode)
                    tmux.canTerminate()
                else
                    true,
                else => true,
            };
            if (terminate) return self.unhook();
            return self.forwardPut(byte);
        }

        return self.forwardPut(byte);
    }

    /// Forward a byte to the appropriate sub-handler.
    fn forwardPut(self: *Handler, byte: u8) ?Command {
        return self.tryPut(byte) catch |err| {
            log.info("error putting byte into DCS handler err={}", .{err});
            // ROOTSHELL-TMUX (id=dcs-tmux-put-error): a failure inside the
            // tmux control parser (its buffer cap, allocation failure) must
            // surface as `.broken` so the stream handler tears the gateway
            // down VISIBLY (prune tabs, force-unhook, back to a shell).
            // Falling into `.ignore` here made the handler a silent byte
            // sink: the viewer stayed alive, every pane froze blank, and no
            // error appeared anywhere — the worst failure mode this channel
            // has. `.inactive` (not `.ignore`) so dcsConsumeGroundRequest
            // grounds the VT parser on the next byte.
            if (comptime build_options.tmux_control_mode) {
                if (self.state == .tmux) {
                    self.discard();
                    self.state = .inactive;
                    return .{ .tmux = .broken };
                }
            }
            self.discard();
            self.state = .ignore;
            return null;
        };
    }

    fn tryPut(self: *Handler, byte: u8) !?Command {
        switch (self.state) {
            .inactive,
            .ignore,
            => {},

            .tmux => |*tmux| if (comptime build_options.tmux_control_mode) {
                return .{
                    .tmux = (try tmux.put(byte)) orelse return null,
                };
            } else unreachable,

            .xtgettcap => |*list| {
                if (list.written().len >= self.max_bytes) {
                    return error.OutOfMemory;
                }

                try list.writer.writeByte(byte);
            },

            .decrqss => |*buffer| {
                if (buffer.len >= buffer.data.len) {
                    return error.OutOfMemory;
                }

                buffer.data[buffer.len] = byte;
                buffer.len += 1;
            },
        }

        return null;
    }

    /// Engage control-parser resync on the active tmux control parser. No-op if
    /// the handler is not currently in the tmux DCS state. Called on a
    /// control-mode RESUME (the iOS app reattached a live `tmux -CC`) so the
    /// freshly-hooked parser realigns to a clean line boundary instead of
    /// breaking on the arbitrary mid-stream reattach garbage. ROOTSHELL-TMUX
    /// (id=dcs-begin-tmux-resync)
    pub fn beginTmuxResync(self: *Handler) void {
        if (comptime !build_options.tmux_control_mode) return;
        switch (self.state) {
            .tmux => |*tmux| tmux.beginResync(),
            else => {},
        }
    }

    /// Take-and-clear the control parser's recovery-request edge (see
    /// `control.Parser.recover_pending`). The stream handler calls this after
    /// feeding each byte; a true result means a framing desync / mid-stream data
    /// loss was detected and the gateway should drive a live re-resync. No-op
    /// (false) unless currently in the tmux DCS state. ROOTSHELL-TMUX
    /// (id=dcs-tmux-take-recover)
    pub fn tmuxTakeRecoverRequest(self: *Handler) bool {
        if (comptime !build_options.tmux_control_mode) return false;
        return switch (self.state) {
            .tmux => |*tmux| tmux.takeRecoverRequest(),
            else => false,
        };
    }

    /// Arm the control parser's probe-echo detach scan (see
    /// `control.Parser.probe_echo`) with the just-written probe's nonce.
    /// Called by the stream handler right after a recovery-resync probe was
    /// queued for a viewer with projected topology. No-op unless currently in
    /// the tmux DCS state. ROOTSHELL-TMUX (id=dcs-tmux-probe-echo)
    pub fn armTmuxProbeEcho(
        self: *Handler,
        nonce: [@import("tmux_cc/probe_echo.zig").ProbeEchoMatcher.nonce_len]u8,
    ) void {
        if (comptime !build_options.tmux_control_mode) return;
        switch (self.state) {
            .tmux => |*tmux| tmux.armProbeEcho(nonce),
            else => {},
        }
    }

    /// Take-and-clear the control parser's dead-shell detach edge (see
    /// `control.Parser.detach_pending`). A true result means our resync probe
    /// was echoed back by a plain shell — tmux exited but its `%exit` was
    /// lost — and the gateway should tear down exactly like a clean `%exit`.
    /// No-op (false) unless currently in the tmux DCS state. ROOTSHELL-TMUX
    /// (id=dcs-tmux-probe-echo)
    pub fn tmuxTakeDetachRequest(self: *Handler) bool {
        if (comptime !build_options.tmux_control_mode) return false;
        return switch (self.state) {
            .tmux => |*tmux| tmux.takeDetachRequest(),
            else => false,
        };
    }

    pub fn unhook(self: *Handler) ?Command {
        // Note: we do NOT call deinit here on purpose because some commands
        // transfer memory ownership. If state needs cleanup, the switch
        // prong below should handle it.
        self.pending_esc = false;
        defer self.state = .inactive;

        return switch (self.state) {
            .inactive,
            .ignore,
            => null,

            .tmux => if (comptime build_options.tmux_control_mode) tmux: {
                self.state.deinit();
                break :tmux .{ .tmux = .exit };
            } else unreachable,

            .xtgettcap => |*list| xtgettcap: {
                // Note: purposely do not deinit our state here because
                // we copy it into the resulting command.
                const items = list.written();
                for (items, 0..) |b, i| items[i] = std.ascii.toUpper(b);
                break :xtgettcap .{ .xtgettcap = .{ .data = list.* } };
            },

            .decrqss => |buffer| .{ .decrqss = switch (buffer.len) {
                0 => .none,
                1 => switch (buffer.data[0]) {
                    'm' => .sgr,
                    'r' => .decstbm,
                    's' => .decslrm,
                    else => .none,
                },
                2 => switch (buffer.data[0]) {
                    ' ' => switch (buffer.data[1]) {
                        'q' => .decscusr,
                        else => .none,
                    },
                    else => .none,
                },
                else => unreachable,
            } },
        };
    }

    fn discard(self: *Handler) void {
        self.pending_esc = false;
        self.state.deinit();
        self.state = .inactive;
    }

    /// Whether no control string is in progress (the DCS handler has unhooked /
    /// aborted and returned to .inactive). The fork's parse table never leaves
    /// dcs_passthrough on ESC / C1 / CAN / SUB (so a tmux control payload isn't
    /// cut short), so `terminal.stream` asks this — via the stream handler's
    /// `dcsConsumeGroundRequest` — after each `dcs_put` to detect that our own
    /// ST / abort handling above has ended the DCS, and returns the parser to
    /// ground. Without it an ordinary DCS would wedge the parser. ROOTSHELL-TMUX
    /// (id=dcs-is-inactive)
    pub fn isInactive(self: *const Handler) bool {
        return switch (self.state) {
            .inactive => true,
            else => false,
        };
    }
};

pub const Command = union(enum) {
    /// XTGETTCAP
    xtgettcap: XTGETTCAP,

    /// DECRQSS
    decrqss: DECRQSS,

    /// Tmux control mode
    tmux: if (build_options.tmux_control_mode)
        terminal.tmux.ControlNotification
    else
        void,

    pub fn deinit(self: *Command) void {
        switch (self.*) {
            .xtgettcap => |*v| v.data.deinit(),
            .decrqss => {},
            .tmux => {},
        }
    }

    pub const XTGETTCAP = struct {
        data: std.Io.Writer.Allocating,
        i: usize = 0,

        /// Returns the next terminfo key being requested and null
        /// when there are no more keys. The returned value is NOT hex-decoded
        /// because we expect to use a comptime lookup table.
        pub fn next(self: *XTGETTCAP) ?[]const u8 {
            const items = self.data.written();
            if (self.i >= items.len) return null;
            var rem = items[self.i..];
            const idx = std.mem.indexOf(u8, rem, ";") orelse rem.len;

            // Note that if we're at the end, idx + 1 is len + 1 so we're over
            // the end but that's okay because our check above is >= so we'll
            // never read.
            self.i += idx + 1;

            return rem[0..idx];
        }
    };

    /// Supported DECRQSS settings
    pub const DECRQSS = enum {
        none,
        sgr,
        decscusr,
        decstbm,
        decslrm,
    };
};

const State = union(enum) {
    /// We're not in a DCS state at the moment.
    inactive,

    /// We're hooked, but its an unknown DCS command or one that went
    /// invalid due to some bad input, so we're ignoring the rest.
    ignore,

    /// XTGETTCAP
    xtgettcap: std.Io.Writer.Allocating,

    /// DECRQSS
    decrqss: struct {
        data: [2]u8 = undefined,
        len: u2 = 0,
    },

    /// Tmux control mode: https://github.com/tmux/tmux/wiki/Control-Mode
    tmux: if (build_options.tmux_control_mode)
        terminal.tmux.ControlParser
    else
        void,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive,
            .ignore,
            => {},

            .xtgettcap => |*v| v.deinit(),
            .decrqss => {},
            .tmux => |*v| if (comptime build_options.tmux_control_mode) {
                v.deinit();
            } else unreachable,
        }
    }
};

test "unknown DCS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .final = 'A' }) == null);
    try testing.expect(h.state == .ignore);
    try testing.expect(h.unhook() == null);
    try testing.expect(h.state == .inactive);
}

test "XTGETTCAP command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP mixed case" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536d756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command multiple keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536D756C78;536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command invalid data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("who;536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("WHO", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "DECRQSS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('m');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .sgr);
}

test "DECRQSS invalid command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('z');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .none);

    h.discard();

    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('"');
    _ = h.put(' ');
    _ = h.put('q');
    try testing.expect(h.unhook() == null);
}

test "tmux enter and implicit exit" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .enter);
    }

    {
        var cmd = h.unhook().?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .exit);
    }
}

test "7-bit ST (ESC \\) terminates DCS via put" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use XTGETTCAP as a simple DCS to test with
    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);

    // Put some data
    for ("536D756C78") |byte| _ = h.put(byte);

    // Now send ESC \ (7-bit ST)
    try testing.expect(h.put(0x1B) == null); // ESC buffered
    var cmd = h.put(0x5C).?; // '\' completes ST → unhook
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);

    // Handler should be inactive after ST
    try testing.expect(h.state == .inactive);
    try testing.expect(h.pending_esc == false);
}

test "ESC followed by non-backslash is forwarded" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use XTGETTCAP as a simple DCS to test with
    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);

    // Put some data
    for ("AB") |byte| _ = h.put(byte);

    // Send ESC followed by '[' (not ST — this is CSI start)
    try testing.expect(h.put(0x1B) == null); // ESC buffered
    try testing.expect(h.put('[') == null); // Not ST, both bytes forwarded

    // The ESC and '[' should be in the buffer
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    // Buffer should contain: "AB" + ESC + "["
    try testing.expectEqualStrings("AB\x1b[", cmd.xtgettcap.next().?);
}

test "tmux: ESC in block content does not cause exit" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .enter);
    }

    // Simulate tmux sending a %begin block with embedded ESC sequences
    // (like capture-pane -e output with SGR codes)
    const block_with_esc =
        "%begin 1234 1 0\n" ++
        "\x1b[32mhello\x1b[0m\n" ++ // SGR green + reset
        "%end 1234 1 0\n";

    var got_block_end = false;
    for (block_with_esc) |byte| {
        if (h.put(byte)) |cmd| {
            // We should get a tmux block_end notification, NOT an exit
            try testing.expect(cmd == .tmux);
            switch (cmd.tmux) {
                .exit => return error.TestUnexpectedResult,
                .block_end => {
                    got_block_end = true;
                },
                else => {},
            }
        }
    }

    // We should still be in tmux state (not exited)
    try testing.expect(h.state == .tmux);
    try testing.expect(got_block_end);
}

test "tmux: ESC CAN / ESC SUB in block content is forwarded, not dropped" {
    // Regression: the CAN/SUB abort handling must flush a pending ESC before
    // forwarding the CAN/SUB in tmux state, otherwise an `ESC CAN` / `ESC SUB`
    // embedded in control payload loses the ESC byte (and never aborts/exits).
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .enter);
    }

    // Block content carrying ESC CAN (0x1B 0x18) and ESC SUB (0x1B 0x1A).
    const block =
        "%begin 1234 1 0\n" ++
        "a\x1b\x18b\x1b\x1ac\n" ++
        "%end 1234 1 0\n";

    var got_block_end = false;
    for (block) |byte| {
        if (h.put(byte)) |cmd| {
            try testing.expect(cmd == .tmux);
            switch (cmd.tmux) {
                .exit => return error.TestUnexpectedResult,
                .block_end => got_block_end = true,
                else => {},
            }
        }
    }

    // Control mode intact (CAN/SUB did not abort/exit it) and the block parsed.
    try testing.expect(h.state == .tmux);
    try testing.expect(got_block_end);
    try testing.expect(h.pending_esc == false);
}

test "tmux: 7-bit ST after %exit exits tmux control mode" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .enter);
    }

    // tmux's real shutdown sequence: a %exit notification line, THEN the ST.
    // ROOTSHELL-TMUX (id=control-st-after-exit)
    for ("%exit") |byte| try testing.expect(h.put(byte) == null);
    {
        var cmd = h.put('\n').?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .exit);
    }

    // Send ESC \ (7-bit ST) to terminate tmux control mode
    try testing.expect(h.put(0x1B) == null);
    var cmd = h.put(0x5C).?;
    defer cmd.deinit();
    try testing.expect(cmd == .tmux);
    try testing.expect(cmd.tmux == .exit);
    try testing.expect(h.state == .inactive);
}

test "tmux: stray 0x9C in idle without %exit does not unhook; raises recover" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    // A stalled transport redelivering mid-stream bytes can land ANY byte in
    // the idle parser; 0x9C is a common UTF-8 continuation byte in CJK
    // content. It must NOT be honored as the control-mode terminator (which
    // silently leaked the rest of the protocol into the terminal with the
    // viewer still alive); it must take the stray-byte self-heal path
    // instead. ROOTSHELL-TMUX (id=control-st-after-exit)
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd.tmux == .enter);
    }

    try testing.expect(h.put(0x9C) == null);
    try testing.expect(h.state == .tmux); // still hooked
    try testing.expect(h.tmuxTakeRecoverRequest()); // self-heal requested

    // Clean up.
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd.tmux == .exit);
}

test "tmux: stray ESC \\ in idle without %exit does not unhook" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd.tmux == .enter);
    }

    try testing.expect(h.put(0x1B) == null);
    try testing.expect(h.put(0x5C) == null);
    try testing.expect(h.state == .tmux); // still hooked
    try testing.expect(h.tmuxTakeRecoverRequest()); // stray ESC raised self-heal

    // Clean up.
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd.tmux == .exit);
}

test "pending_esc is cleared on hook" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    // Manually set pending_esc (simulating leftover state)
    h.pending_esc = true;

    // Hook into XTGETTCAP — hook should clear pending_esc
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    try testing.expect(h.pending_esc == false);

    // Clean up: unhook so deinit doesn't leak
    var cmd = h.unhook().?;
    cmd.deinit();
}

test "tmux: a block larger than the handler's 1 MiB DCS cap parses fine" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    // ROOTSHELL-TMUX (id=dcs-tmux-max-bytes): the tmux control parser must
    // NOT inherit the handler's 1 MiB anti-malicious-DCS cap. A bounded
    // capture-pane history reply (10k CJK lines) legitimately exceeds 1 MiB
    // in a single %begin/%end block; inheriting the cap broke the parser at
    // exactly 1 MiB and silently ate the rest of the channel (every pane
    // frozen blank on attach — the original field wedge).
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd.tmux == .enter);
    }

    const begin = "%begin 1718000000 5 1\n";
    for (begin) |b| try testing.expect(h.put(b) == null);

    // Feed > 1 MiB of block content (a long line then many short ones).
    var line: [1024]u8 = undefined;
    @memset(&line, 'x');
    line[line.len - 1] = '\n';
    var fed: usize = 0;
    while (fed < (1024 + 64) * 1024) : (fed += line.len) {
        for (line) |b| {
            if (h.put(b)) |cmd_| {
                var cmd = cmd_;
                defer cmd.deinit();
                // No block_end/broken/exit may fire mid-content.
                try testing.expect(false);
            }
        }
    }
    try testing.expect(h.state == .tmux); // still hooked

    const end = "%end 1718000000 5 1\n";
    var got_end = false;
    for (end) |b| {
        if (h.put(b)) |cmd_| {
            var cmd = cmd_;
            defer cmd.deinit();
            try testing.expect(cmd.tmux == .block_end);
            try testing.expect(cmd.tmux.block_end.content.len > 1024 * 1024);
            got_end = true;
        }
    }
    try testing.expect(got_end);

    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd.tmux == .exit);
}

test "tmux: a control-parser put failure surfaces as .broken, not silent .ignore" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    // ROOTSHELL-TMUX (id=dcs-tmux-put-error): when the tmux parser errors
    // (its hard buffer cap), the handler must emit `.broken` so the stream
    // handler tears the gateway down visibly. The old path flipped to
    // `.ignore` and silently ate the channel forever.
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd.tmux == .enter);
    }

    // Force the parser's own hard cap low to simulate the failure.
    h.state.tmux.max_bytes = 8;

    const input = "%begin 1 2 1\nabcdefghijklmnop";
    var got_broken = false;
    for (input) |b| {
        if (h.put(b)) |cmd_| {
            var cmd = cmd_;
            defer cmd.deinit();
            try testing.expect(cmd.tmux == .broken);
            got_broken = true;
            break;
        }
    }
    try testing.expect(got_broken);
    // Handler is inactive so the stream grounds on the next byte.
    try testing.expect(h.isInactive());
}
