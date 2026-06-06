// ROOTSHELL-TMUX: this upstream-shared file carries the fork's
// `tmux_set_client_size` termio message variant. Grep "ROOTSHELL-TMUX" here for
// every hook. See docs/tmux-control-mode-fork.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The messages that can be sent to an IO thread.
///
/// This is not a tiny structure (~40 bytes at the time of writing this comment),
/// but the messages are IO thread sends are also very few. At the current size
/// we can queue 26,000 messages before consuming a MB of RAM.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the largest
    /// other union value. It can be upped if we add a larger union member
    /// in the future.
    pub const WriteReq = MessageData(u8, 38);

    /// Request a color scheme report is sent to the pty.
    color_scheme_report: struct {
        /// Force write the current color scheme
        force: bool,
    },

    /// Purposely crash the renderer. This is used for testing and debugging.
    /// See the "crash" binding action.
    crash: void,

    /// The derived configuration to update the implementation with. This
    /// is allocated via the allocator and is expected to be freed when done.
    change_config: struct {
        alloc: Allocator,
        ptr: *termio.Termio.DerivedConfig,
    },

    /// Activate or deactivate the inspector.
    inspector: bool,

    /// Resize the window.
    resize: renderer.Size,

    /// Request a size report is sent to the pty ([in-band
    /// size report, mode 2048](https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83) and
    /// [XTWINOPS](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Functions-using-CSI-_-ordered-by-the-final-character-lparen-s-rparen:CSI-Ps;Ps;Ps-t.1EB0)).
    size_report: SizeReport,

    /// Clear the screen.
    clear_screen: struct {
        /// Include clearing the history
        history: bool,
    },

    /// Scroll the viewport
    scroll_viewport: terminal.Terminal.ScrollViewport,

    /// Selection scrolling. If this is set to true then the termio
    /// thread starts a timer that will trigger a `selection_scroll_tick`
    /// message back to the surface. This ping/pong is because the
    /// surface thread doesn't have access to an event loop from libghostty.
    selection_scroll: bool,

    /// Jump forward/backward n prompts.
    jump_to_prompt: isize,

    /// Set the tmux control-mode client size (cols x rows in cells). Handled on
    /// the IO thread so it can safely touch the viewer's command queue. The
    /// stream handler sends `refresh-client -C <cols>x<rows>` to tmux so the
    /// active window's panes are laid out to the visible tab's size. No-op when
    /// no tmux viewer is active.
    tmux_set_client_size: struct { // ROOTSHELL-TMUX (id=termio-msg-set-client-size)
        cols: u16,
        rows: u16,
    },

    /// A raw, pre-formatted tmux command (with trailing newline) relayed from a
    /// child pane backend (resize-pane / select-pane / select-window). Handled
    /// on the IO thread so it can be routed through the viewer's command queue
    /// instead of written straight to tmux, keeping the command/response FIFO
    /// aligned (a stray untracked block otherwise blanks a pane on attach).
    /// `data` is owned and freed after handling. See
    /// `StreamHandler.tmuxQueuePaneCommand`.
    tmux_pane_command: struct { // ROOTSHELL-TMUX (id=termio-msg-pane-command)
        alloc: Allocator,
        data: []const u8,
    },

    /// Untracked `send-keys` (typed input / paste / focus reports) relayed from a
    /// child pane backend. Written straight to the `tmux -CC` pty (no command-
    /// queue gating, so keystroke latency is unchanged) and then recorded as an
    /// `.untracked` marker in the viewer's sent-FIFO so its `%begin/%end` ack is
    /// matched/swallowed in order instead of being mis-attributed to an in-flight
    /// tracked command (which would desync the response FIFO). `data` is owned and
    /// freed after handling. See `StreamHandler.recordTmuxUntrackedSend`.
    tmux_send_keys: struct { // ROOTSHELL-TMUX (id=termio-msg-send-keys)
        alloc: Allocator,
        data: []const u8,
    },

    /// A tracked tmux command (already formatted, with trailing newline) emitted
    /// by the viewer. Written to the pty and then recorded as a `.tracked` marker
    /// in the viewer's sent-FIFO. Recording happens at this single drain/write
    /// point (NOT at the viewer enqueue site) because the SPSC mailbox can reorder
    /// the actual write behind a `send-keys` already queued ahead of it; recording
    /// after the write guarantees marker order == pty write order == tmux block
    /// order. `data` is owned and freed after handling. See
    /// `StreamHandler.recordTmuxTrackedSend`.
    tmux_track_command: struct { // ROOTSHELL-TMUX (id=termio-msg-track-command)
        alloc: Allocator,
        data: []const u8,
    },

    /// Detach the tmux control-mode client for this surface's viewer. Handled on
    /// the IO thread so it can queue a `detach-client` through the viewer's
    /// command queue (FIFO-safe, NOT a raw write that would desync the response
    /// FIFO). tmux replies %exit, which tears the viewer down and lets the
    /// `tmux -CC` process exit back to its shell. No-op when no tmux viewer is
    /// active. See `StreamHandler.tmuxDetach`.
    tmux_detach: void, // ROOTSHELL-TMUX (id=termio-msg-detach)

    /// Send this when a synchronized output mode is started. This will
    /// start the timer so that the output mode is disabled after a
    /// period of time so that a bad actor can't hang the terminal.
    start_synchronized_output: void,

    /// Enable or disable linefeed mode (mode 20).
    linefeed_mode: bool,

    /// The surface gained or lost focus.
    focused: bool,

    /// Write where the data fits in the union.
    write_small: WriteReq.Small,

    /// Write where the data pointer is stable.
    write_stable: WriteReq.Stable,

    /// Write where the data is allocated and must be freed.
    write_alloc: WriteReq.Alloc,

    /// Return a write request for the given data. This will use
    /// write_small if it fits or write_alloc otherwise. This should NOT
    /// be used for stable pointers which can be manually set to write_stable.
    pub fn writeReq(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .write_small = v },
            .alloc => |v| Message{ .write_alloc = v },
        };
    }

    /// Frees any owned allocations in this message when it could not be
    /// enqueued and therefore will never be processed by the IO thread.
    pub fn deinitDropped(self: Message) void {
        switch (self) {
            .change_config => |config| {
                config.ptr.deinit();
                config.alloc.destroy(config.ptr);
            },
            .write_alloc => |req| req.alloc.free(req.data),
            .tmux_pane_command => |v| v.alloc.free(v.data),
            .tmux_send_keys => |v| v.alloc.free(v.data), // ROOTSHELL-TMUX (id=termio-msg-send-keys)
            .tmux_track_command => |v| v.alloc.free(v.data), // ROOTSHELL-TMUX (id=termio-msg-track-command)
            else => {},
        }
    }

    /// The types of size reports that we support.
    pub const SizeReport = terminal.size_report.Style;
};

test {
    std.testing.refAllDecls(@This());
}

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(Message));
}
