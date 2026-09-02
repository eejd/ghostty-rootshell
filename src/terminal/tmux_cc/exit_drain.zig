//! ROOTSHELL-TMUX (id=exit-drain): post-force-exit control-backlog drain.
//!
//! When the recovery watchdog force-exits tmux control mode locally
//! (`tmuxForceExit`), the remote `tmux -CC` client is still attached and the
//! transport may still deliver a large swallowed control-protocol backlog
//! (capture-pane replies, %output lines, guard lines) plus — after our
//! best-effort `detach-client` — a real `%exit` line followed by ST.
//! (`tmuxForceExit` itself never contacts tmux; the `%exit` this drain waits
//! for comes from the SWIFT side's best-effort raw `detach-client` write,
//! sent right after it requests the force-exit. If that write is lost or the
//! remote client outlives us, the budget/deadline below bounds the drain and
//! the residual backlog paints — same as before, just bounded.) With the
//! DCS parser unhooked, all of that would paint raw garbage into the revealed
//! gateway shell (the `�普通…` / `%begin … %exit` flood users reported).
//!
//! This is a pure rolling matcher over the discarded stream: it consumes
//! (discards) bytes until a line that BEGINS with `%exit` has been consumed
//! AND the following ST (7-bit `ESC \` or 8-bit 0x9C) has been consumed, or
//! until a fresh ESC begins a replacement control-mode DCS, or until a byte
//! budget / wall-clock deadline expires. Bytes after the boundary are returned
//! to normal processing; notably the fresh ESC is not consumed, so the VT
//! parser receives the replacement `ESC P 1000 p` preamble intact.
//!
//! Pure state machine — no allocation, no clock access (the caller passes
//! `now_ms`) — so chunk-boundary behavior is unit-testable byte by byte.

const std = @import("std");

pub const ExitDrain = struct {
    /// Wall-clock ms after which the drain gives up and stops consuming.
    deadline_ms: i64,

    /// Remaining bytes the drain may discard before giving up.
    budget: usize,

    state: State = .line_start,

    /// Progress through the literal "%exit" while in `.matching`.
    match_idx: usize = 0,

    /// In `.await_st`: a 0x1B was seen, awaiting the '\' that completes ST.
    esc_pending: bool = false,

    pub const default_budget: usize = 4 * 1024 * 1024;
    pub const default_deadline_ms: i64 = 10 * std.time.ms_per_s;

    const State = enum {
        /// At the start of a line; a '%' here may begin the `%exit` match.
        line_start,
        /// Inside a non-matching line; discard until '\n'.
        mid_line,
        /// Matching the literal "%exit" from a line start.
        matching,
        /// Line began with `%exit` (followed by space/CR/NL); discard the
        /// rest of the line.
        matched_line,
        /// `%exit` line consumed; discard until the closing ST.
        await_st,
        /// Boundary (or budget/deadline) reached; consume nothing more.
        done,
    };

    const needle = "%exit";

    pub fn init(now_ms: i64) ExitDrain {
        return .{
            .deadline_ms = now_ms + default_deadline_ms,
            .budget = default_budget,
        };
    }

    pub fn isDone(self: *const ExitDrain) bool {
        return self.state == .done;
    }

    /// Consume (discard) bytes from `chunk`. Returns the number of bytes
    /// consumed; when it is less than `chunk.len` the drain is finished and
    /// the remainder must be fed to the normal processing path. The drain is
    /// also finished when `isDone()` is true after the call.
    pub fn feed(self: *ExitDrain, chunk: []const u8, now_ms: i64) usize {
        if (self.state == .done) return 0;
        if (now_ms >= self.deadline_ms) {
            self.state = .done;
            return 0;
        }

        var i: usize = 0;
        while (i < chunk.len) : (i += 1) {
            if (self.budget == 0) {
                self.state = .done;
                return i;
            }
            const c = chunk[i];

            // A replacement `tmux -CC` starts a fresh DCS with ESC P 1000 p.
            // Stop BEFORE consuming ESC so the normal VT path sees the entire
            // preamble and hooks the new control viewer. Control-mode payload
            // escapes terminal ESC bytes, so before the old `%exit` boundary a
            // raw ESC is either this fresh handoff or a closing ST whose `%exit`
            // was lost; returning either to the ground parser is safe. Do not
            // take this branch while awaiting the known old ST: that boundary
            // must still be consumed by the drain below.
            if (c == 0x1B and self.state != .await_st) {
                self.state = .done;
                return i;
            }
            self.budget -= 1;

            switch (self.state) {
                .done => unreachable,

                .line_start => if (c == needle[0]) {
                    self.state = .matching;
                    self.match_idx = 1;
                } else if (c == '\n') {
                    // stay at line_start
                } else {
                    self.state = .mid_line;
                },

                .mid_line => if (c == '\n') {
                    self.state = .line_start;
                },

                .matching => if (self.match_idx < needle.len) {
                    if (c == needle[self.match_idx]) {
                        self.match_idx += 1;
                    } else if (c == '\n') {
                        self.state = .line_start;
                    } else {
                        self.state = .mid_line;
                    }
                } else {
                    // Full "%exit" matched; require a line/word boundary so
                    // pane content like "%exitcode" can't end the drain.
                    switch (c) {
                        '\n' => self.state = .await_st,
                        '\r', ' ' => self.state = .matched_line,
                        else => self.state = .mid_line,
                    }
                },

                .matched_line => if (c == '\n') {
                    self.state = .await_st;
                },

                .await_st => if (self.esc_pending) {
                    self.esc_pending = false;
                    if (c == '\\') {
                        self.state = .done;
                        return i + 1;
                    }
                    if (c == 0x1B) self.esc_pending = true;
                } else if (c == 0x9C) {
                    self.state = .done;
                    return i + 1;
                } else if (c == 0x1B) {
                    self.esc_pending = true;
                },
            }
        }
        return chunk.len;
    }
};

test "exit drain: simple %exit + 7-bit ST then shell bytes" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    const input = "%begin 1 2 1\ngarbage\n%exit\n\x1b\\prompt$ ";
    const consumed = d.feed(input, 1);
    try t.expect(d.isDone());
    try t.expectEqualStrings("prompt$ ", input[consumed..]);
}

test "exit drain: 8-bit ST and %exit with reason" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    const input = "%output %1 abc\n%exit detached\n\x9crest";
    const consumed = d.feed(input, 1);
    try t.expect(d.isDone());
    try t.expectEqualStrings("rest", input[consumed..]);
}

test "exit drain: boundary straddles chunks" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    const input = "junk\n%ex" ++ "it" ++ "\n" ++ "\x1b" ++ "\\after";
    // Feed one byte at a time to exercise every split point.
    var consumed_total: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const consumed = d.feed(input[i .. i + 1], 1);
        consumed_total += consumed;
        if (d.isDone()) break;
    }
    try t.expect(d.isDone());
    try t.expectEqualStrings("after", input[consumed_total..]);
}

test "exit drain: %exitcode content does not terminate" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    const consumed = d.feed("%exitcode=1\n\x1b\\more\n", 1);
    try t.expectEqual(@as(usize, 19), consumed);
    try t.expect(!d.isDone());
}

test "exit drain: mid-line %exit does not match" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    const consumed = d.feed("x %exit\n\x1b\\y\n", 1);
    try t.expectEqual(@as(usize, 12), consumed);
    try t.expect(!d.isDone());
}

test "exit drain: budget exhaustion stops consuming" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    d.budget = 4;
    const input = "abcdefgh";
    const consumed = d.feed(input, 1);
    try t.expectEqual(@as(usize, 4), consumed);
    try t.expect(d.isDone());
    // Subsequent feeds consume nothing.
    try t.expectEqual(@as(usize, 0), d.feed("zzz", 1));
}

test "exit drain: deadline expiry stops before consuming" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    try t.expectEqual(@as(usize, 0), d.feed("abc", ExitDrain.default_deadline_ms + 1));
    try t.expect(d.isDone());
}

test "exit drain: ESC ESC \\ still terminates" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    const input = "%exit\n\x1b\x1b\\tail";
    const consumed = d.feed(input, 1);
    try t.expect(d.isDone());
    try t.expectEqualStrings("tail", input[consumed..]);
}

test "exit drain: fresh tmux DCS is handed to normal parser intact" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    const input = "%output %1 stale\n\x1bP1000p%begin 1 2 0\n";
    const consumed = d.feed(input, 1);
    try t.expect(d.isDone());
    try t.expectEqualStrings("\x1bP1000p%begin 1 2 0\n", input[consumed..]);
}

test "exit drain: fresh tmux DCS split before ESC is handed off" {
    const t = std.testing;
    var d = ExitDrain.init(0);
    try t.expectEqual(@as(usize, 6), d.feed("stale\n", 1));
    const input = "\x1bP1000p%begin 1 2 0\n";
    const consumed = d.feed(input, 1);
    try t.expectEqual(@as(usize, 0), consumed);
    try t.expect(d.isDone());
    try t.expectEqualStrings(input, input[consumed..]);
}
