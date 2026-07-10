//! ROOTSHELL-TMUX (id=probe-echo-detach): dead-shell detach detection via
//! probe echo.
//!
//! When mid-stream data loss swallows tmux's `%exit` (tsshd drop-oldest while
//! the app is backgrounded), the control parser stays hooked while the remote
//! PTY is back at a plain shell prompt. The recovery resync then writes the
//! probe (see `Viewer.resync_probe_prefix`) into that shell — and the PTY
//! line discipline ECHOES it back verbatim, including the literal UNEXPANDED
//! `#{session_id}` AND the per-probe random nonce. Neither can appear
//! anywhere else:
//!
//! - a live tmux expands `#{session_id}` to `$N`, and its reply arrives
//!   inside a `%begin/%end` block (which the caller never scans);
//! - the nonce is freshly generated for each probe write and exists only in
//!   that one command string, so pane content that happens to quote the
//!   PUBLIC marker text (these sources, docs, a user echoing the marker)
//!   can never complete a match even when its `%output` framing was lost to
//!   the same corruption that started the resync.
//!
//! This is a pure rolling matcher over the control parser's tolerant-idle
//! byte stream. Terminal echo may wrap the line at the terminal width
//! (`\r\n` injected mid-token) and line editors may repaint with SGR/CSI
//! sequences, so while a match is in progress CR/LF and complete CSI
//! sequences are skipped without resetting the match. After the full needle
//! matches, the rest of the echoed line is consumed so it never paints into
//! the revealed shell.
//!
//! Pure state machine — no allocation, no clock (episodes are already
//! time-bounded externally: block completion disarms the matcher and the
//! app-side watchdog force-exits stuck resyncs) — so chunk-boundary behavior
//! is unit-testable byte by byte.

const std = @import("std");

pub const ProbeEchoMatcher = struct {
    /// The per-probe random nonce this matcher was armed with; the needle is
    /// `needle_prefix ++ nonce ++ "'"`.
    nonce: [nonce_len]u8,

    /// Remaining bytes the matcher may scan before giving up.
    budget: usize = default_budget,

    state: State = .matching,

    /// Progress through the needle while in `.matching`.
    match_idx: usize = 0,

    /// Escape-sequence skipper, active only while mid-match.
    esc: EscState = .none,

    /// Remaining bytes `.drain_line` may consume before force-completing.
    drain_budget: usize = drain_line_max,

    /// The static leg of the needle: the marker plus the UNEXPANDED
    /// `#{session_id}` (tmux expands it to `$N` in every genuine reply). The
    /// per-probe nonce and the closing quote follow. Kept in sync with
    /// `Viewer.resync_probe_prefix` by a comptime assert in viewer.zig.
    pub const needle_prefix = "__ROOTSHELL_TMUX_RESYNC__ #{session_id} ";

    /// Hex chars of per-probe nonce carried inside the probe's quoted string.
    pub const nonce_len = 8;

    pub const default_budget: usize = 4 * 1024 * 1024;
    pub const drain_line_max: usize = 512;

    const needle_len = needle_prefix.len + nonce_len + 1; // +1: closing quote

    const State = enum {
        /// Scanning for the needle.
        matching,
        /// Needle matched; consuming the rest of the echoed line.
        drain_line,
        /// Matched or exhausted; consumes nothing more.
        done,
    };

    const EscState = enum { none, esc, csi };

    pub const Result = enum { pending, matched, exhausted };

    pub fn init(nonce: [nonce_len]u8) ProbeEchoMatcher {
        return .{ .nonce = nonce };
    }

    fn needleByte(self: *const ProbeEchoMatcher, idx: usize) u8 {
        if (idx < needle_prefix.len) return needle_prefix[idx];
        if (idx < needle_prefix.len + nonce_len) return self.nonce[idx - needle_prefix.len];
        return '\'';
    }

    pub fn feed(self: *ProbeEchoMatcher, byte: u8) Result {
        switch (self.state) {
            // Defensive: the owner disarms (drops) the matcher on
            // matched/exhausted, so this should not be reached.
            .done => return .pending,

            .drain_line => {
                if (byte == '\n' or self.drain_budget == 0) {
                    self.state = .done;
                    return .matched;
                }
                self.drain_budget -= 1;
                return .pending;
            },

            .matching => {},
        }

        if (self.budget == 0) {
            self.state = .done;
            return .exhausted;
        }
        self.budget -= 1;

        // While mid-match, tolerate terminal-echo artifacts injected inside
        // the token: line wraps (\r\n) and complete CSI sequences (repaint
        // colors). CSI bodies are parameter/intermediate bytes and cannot
        // carry needle characters, so skipping them cannot hide a mismatch.
        if (self.match_idx > 0) {
            switch (self.esc) {
                .csi => {
                    if (byte >= 0x40 and byte <= 0x7E) self.esc = .none;
                    return .pending;
                },
                .esc => {
                    self.esc = .none;
                    if (byte == '[') {
                        self.esc = .csi;
                        return .pending;
                    }
                    // Non-CSI escape: the ESC itself was skipped; process
                    // this byte normally below.
                },
                .none => {},
            }
            if (byte == 0x1B) {
                self.esc = .esc;
                return .pending;
            }
            if (byte == '\r' or byte == '\n') return .pending;
        }

        if (byte == self.needleByte(self.match_idx)) {
            self.match_idx += 1;
            if (self.match_idx == needle_len) self.state = .drain_line;
            return .pending;
        }

        // Mismatch: restart; the byte may itself begin a new match.
        self.match_idx = if (byte == self.needleByte(0)) 1 else 0;
        return .pending;
    }
};

const test_nonce: [ProbeEchoMatcher.nonce_len]u8 = "ab12cd34".*;

/// Test helper: feed `input` byte by byte; return the index at which
/// `.matched` was returned, or null if it never was.
fn feedAll(m: *ProbeEchoMatcher, input: []const u8) ?usize {
    for (input, 0..) |byte, i| {
        switch (m.feed(byte)) {
            .matched => return i,
            .exhausted => return null,
            .pending => {},
        }
    }
    return null;
}

test "probe echo: plain echoed probe line matches at newline" {
    const t = std.testing;
    var m: ProbeEchoMatcher = .init(test_nonce);
    const input = "junk$ display-message -p '__ROOTSHELL_TMUX_RESYNC__ #{session_id} ab12cd34'\r\n";
    const idx = feedAll(&m, input) orelse return error.TestExpectedMatch;
    // The drain consumes the tail; the match completes on the line's \n.
    try t.expectEqual(input.len - 1, idx);
}

test "probe echo: wrong nonce never matches" {
    const t = std.testing;
    var m: ProbeEchoMatcher = .init(test_nonce);
    // Identical public text with a different (stale/foreign) nonce — e.g.
    // pane output replaying an OLD probe echo after framing loss.
    try t.expect(feedAll(&m, "'__ROOTSHELL_TMUX_RESYNC__ #{session_id} ffffffff'\n") == null);
}

test "probe echo: public marker text without nonce never matches" {
    const t = std.testing;
    var m: ProbeEchoMatcher = .init(test_nonce);
    // A user viewing these sources/docs in a pane whose %output framing was
    // lost: the public constant appears, the per-probe nonce cannot.
    try t.expect(feedAll(&m, "needle_prefix = \"__ROOTSHELL_TMUX_RESYNC__ #{session_id} \";\n") == null);
}

test "probe echo: needle split by terminal-width wrap still matches" {
    const t = std.testing;
    var m: ProbeEchoMatcher = .init(test_nonce);
    const input = "$ display-message -p '__ROOTSHELL_TMUX_RESYNC_" ++ "\r\n" ++ "_ #{session_id} ab" ++ "\r\n" ++ "12cd34'\n";
    try t.expect(feedAll(&m, input) != null);
}

test "probe echo: SGR sequence mid-token still matches" {
    const t = std.testing;
    var m: ProbeEchoMatcher = .init(test_nonce);
    const input = "'__ROOTSHELL_TMUX" ++ "\x1b[33m" ++ "_RESYNC__ #{session_id} ab12cd34'\n";
    try t.expect(feedAll(&m, input) != null);
}

test "probe echo: budget exhaustion disarms and never matches" {
    const t = std.testing;
    var m: ProbeEchoMatcher = .init(test_nonce);
    m.budget = 8;
    var i: usize = 0;
    var exhausted = false;
    while (i < 16) : (i += 1) {
        switch (m.feed('x')) {
            .exhausted => {
                exhausted = true;
                break;
            },
            .matched => return error.TestUnexpectedMatch,
            .pending => {},
        }
    }
    try t.expect(exhausted);
    // Even the real needle no longer matches once done.
    try t.expect(feedAll(&m, ProbeEchoMatcher.needle_prefix ++ "ab12cd34'\n") == null);
}

test "probe echo: drain line bound force-completes without newline" {
    const t = std.testing;
    var m: ProbeEchoMatcher = .init(test_nonce);
    var matched = false;
    for (ProbeEchoMatcher.needle_prefix ++ "ab12cd34'") |byte| {
        try t.expectEqual(ProbeEchoMatcher.Result.pending, m.feed(byte));
    }
    var i: usize = 0;
    while (i < ProbeEchoMatcher.drain_line_max + 8) : (i += 1) {
        switch (m.feed('y')) {
            .matched => {
                matched = true;
                break;
            },
            .exhausted => return error.TestUnexpectedExhaustion,
            .pending => {},
        }
    }
    try t.expect(matched);
}

test "probe echo: expanded marker reply text does not match" {
    const t = std.testing;
    var m: ProbeEchoMatcher = .init(test_nonce);
    // A genuine reply expands #{session_id} to $N — no `#{` after the marker
    // (and even the nonce is present there; the unexpanded format is the gate).
    try t.expect(feedAll(&m, "__ROOTSHELL_TMUX_RESYNC__ $3 ab12cd34\r\n") == null);
}
