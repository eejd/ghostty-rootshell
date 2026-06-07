//! Tmux implements a termio backend for tmux control mode panes. Unlike the
//! exec backend, this does not spawn a subprocess or allocate a pty. Instead,
//! it routes terminal I/O through a tmux control mode connection that is
//! owned by a parent terminal surface.
//!
//! ROOTSHELL-TMUX: fork-owned file, no upstream equivalent. Carry forward
//! verbatim on rebase. See docs/tmux-control-mode-fork.md.
//!
//! User input (keyboard, paste, etc.) is formatted as tmux `send-keys -H`
//! commands targeting a specific pane, and written to the control connection
//! via the ControlWriter interface. The `ParentWriter` implementation routes
//! commands through the parent terminal's termio mailbox, which writes them
//! to the pty connected to `tmux -CC`. The parent terminal's stream handler
//! is responsible for routing `%output` notifications back to this backend's
//! terminal.
//!
//! This backend's types are always compiled into the backend union so that
//! switch exhaustiveness checks cover it. Actual usage (creating a tmux
//! surface) is gated at call sites by `tmux_control_mode` build option.
//!
//! ## Threading
//!
//! The ControlWriter is invoked on the IO thread of the child surface.
//! The `ParentWriter` implementation posts write requests to the parent's
//! SPSC termio mailbox. See `ParentWriter` doc comments for the full
//! threading contract. `apprt.surface.SurfaceRelayWriter` provides the
//! cross-thread relay path through the app mailbox.
const Tmux = @This();

const std = @import("std");
const xev = @import("../global.zig").xev;
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const apprt = @import("../apprt.zig");

const log = std.log.scoped(.io_tmux);

/// The pane ID this backend is attached to within the tmux session.
/// This is the numeric ID used in tmux's `%`-prefixed pane identifiers
/// (e.g., pane_id 5 corresponds to `%5`).
pane_id: usize,

/// The tmux window ID this pane belongs to. Used to send `select-window`
/// when the surface gains focus, keeping tmux's active window in sync
/// with Ghostty's focused tab.
window_id: usize,

/// Pointer to the viewer-owned terminal for this pane. When set, the
/// renderer's terminal pointer is swapped at `threadEnter` to read
/// directly from the viewer's terminal state rather than the Termio's
/// internal (unused) terminal. This implements Mitchell's single-terminal
/// architecture: the viewer's pane terminals ARE the terminals; child
/// surfaces render from them.
///
/// Upstream anchor: `src/termio/Options.zig:27-30` — "the IO impl is
/// free to change [the terminal pointer] if that is useful (i.e. doing
/// some sort of dual terminal implementation.)"
viewer_terminal: ?*terminal.Terminal,

/// Pointer to the viewer-owned pane for this surface. Used to register
/// the child surface's renderer mutex back to the pane during
/// `threadEnter`, enabling the viewer to acquire the correct mutex when
/// writing to the shared terminal.
viewer_pane: ?*terminal.tmux.Viewer.Pane,

/// The current grid size, tracked locally so we can issue resize
/// commands when the surface dimensions change.
grid_size: renderer.GridSize,

/// The current screen size in pixels.
screen_size: renderer.ScreenSize,

/// The writer used to send commands to the tmux control mode connection.
/// This is an interface so it can be mocked in tests and swapped for a
/// real implementation (see `ParentWriter`) when wired to the parent
/// terminal.
control_writer: ControlWriter,

/// Re-exported from `terminal.tmux` for convenience — the canonical
/// definition lives in the core layer (`terminal/tmux_cc/control_writer.zig`).
pub const ControlWriter = terminal.tmux.ControlWriter;

/// A ControlWriter implementation that routes tmux commands through
/// the parent terminal's termio mailbox. This posts a write request
/// into the parent's SPSC mailbox, which the parent's IO thread then
/// writes to the pty (connected to `tmux -CC`).
///
/// ## Threading Contract
///
/// This writer is safe to call from the parent's IO thread (the same
/// thread that runs the stream handler). The `.command` viewer action
/// already writes to the parent termio mailbox from the stream handler
/// via the same `Mailbox.send` path.
///
/// When child surfaces run on their own IO threads, the child does NOT
/// call ParentWriter directly. Instead, the child posts a message
/// through `apprt.surface.Mailbox` (which routes via the app thread),
/// and the parent's surface relays the command into its own termio
/// mailbox. This preserves the SPSC invariant: the parent's IO thread
/// remains the single producer.
///
/// ## Lifetime
///
/// The `mailbox` and `alloc` pointers must remain valid for the
/// lifetime of this writer. In practice, the parent `Termio` owns
/// both and outlives all child surfaces it creates.
///
/// ## References
///
/// - `stream_handler.zig` `.command` handler: uses the same
///   `Mailbox.send` path to write viewer commands to the parent pty.
/// - `mailbox.zig`: SPSC send.
pub const ParentWriter = struct {
    mailbox: *termio.Mailbox,
    alloc: Allocator,

    pub fn controlWriter(self: *ParentWriter) ControlWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *anyopaque, data: []const u8) ControlWriter.WriteError!void {
        const self: *ParentWriter = @ptrCast(@alignCast(context));
        const msg = termio.Message.writeReq(self.alloc, data) catch
            return error.WriteFailed;
        // Pass null for the mutex: this writer is called from the
        // parent's IO thread (see Threading Contract above) which does
        // NOT hold the renderer mutex. The slow-path in Mailbox.send
        // unlocks/relocks the mutex when non-null, which would be
        // undefined behavior on an unlocked mutex.
        self.mailbox.send(msg, null);
        self.mailbox.notify();
    }
};

/// Configuration for the tmux backend.
pub const Config = struct {
    /// The tmux pane ID this surface represents.
    pane_id: usize,

    /// The tmux window ID this pane belongs to.
    window_id: usize,

    /// The writer for sending commands to the tmux control connection.
    control_writer: ControlWriter,

    /// Pointer to the viewer-owned terminal for this pane. When non-null,
    /// the child surface's renderer will read from this terminal instead
    /// of the Termio's internal terminal. See `Tmux.viewer_terminal`.
    viewer_terminal: ?*terminal.Terminal = null,

    /// Pointer to the viewer-owned pane. When non-null, the child surface
    /// registers its renderer mutex to the pane during `threadEnter`.
    /// See `Tmux.viewer_pane`.
    viewer_pane: ?*terminal.tmux.Viewer.Pane = null,
};

/// Initialize the tmux backend. This does NOT start any I/O; it only
/// stores the configuration needed to operate.
pub fn init(cfg: Config) Tmux {
    return .{
        .pane_id = cfg.pane_id,
        .window_id = cfg.window_id,
        .viewer_terminal = cfg.viewer_terminal,
        .viewer_pane = cfg.viewer_pane,
        .grid_size = .{},
        .screen_size = .{ .width = 0, .height = 0 },
        .control_writer = cfg.control_writer,
    };
}

pub fn deinit(self: *Tmux) void {
    self.* = undefined;
}

/// Set initial terminal state for this backend. Called once before
/// any I/O begins. This must NOT perform any I/O — only local state
/// updates. The first resize command to tmux will be sent after
/// threadEnter when the runtime resize path is invoked.
pub fn initTerminal(self: *Tmux, term: *terminal.Terminal) void {
    // Store the initial dimensions locally. We intentionally do NOT
    // call resize() here because that emits a command through the
    // ControlWriter, violating the lifecycle contract: initTerminal
    // runs before threadEnter, so no I/O may occur.
    self.grid_size = .{
        .columns = term.cols,
        .rows = term.rows,
    };
    self.screen_size = .{
        .width = term.width_px,
        .height = term.height_px,
    };
}

pub fn threadEnter(
    self: *Tmux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    log.info("tmux backend thread enter pane_id={}", .{self.pane_id});

    // Swap the renderer's terminal pointer to the viewer's pane terminal.
    // This makes the child surface render directly from the viewer-owned
    // terminal, which the parent IO thread feeds via VT output processing.
    // The renderer reads terminal state only under this mutex (see
    // renderer/generic.zig:updateFrame), so the swap is safe here before
    // any rendering begins.
    if (self.viewer_terminal) |vt| {
        io.renderer_state.mutex.lock();
        defer io.renderer_state.mutex.unlock();
        io.renderer_state.terminal = vt;
    }

    // Register this child surface's renderer mutex and wake callback back to
    // the viewer pane, and clear the en-route flag. The viewer (parent gateway
    // IO thread) acquires the mutex before writing to the shared terminal and
    // invokes the wake callback after, both coordinating with this child's
    // renderer thread. `Pane.attachRenderer` publishes all of this with release
    // ordering so the gateway never observes a half-built handshake on a
    // weakly-ordered target (see `Pane`'s id=viewer-pane-atomics notes). The
    // wake context `&io.renderer_wakeup` is stable for the lifetime of the
    // child surface's IO and is cleared in threadExit before teardown; the
    // child's own IO thread (this tmux backend) never processes pane output, so
    // without the explicit wake the pane would not repaint until some unrelated
    // event (the source of the "super slow" pane behavior).
    if (self.viewer_pane) |pane| {
        pane.attachRenderer(
            io.renderer_state.mutex,
            @ptrCast(&io.renderer_wakeup),
            &wakeRenderer,
        );
    }

    // Populate the thread data with our (empty) thread state.
    td.backend = .{ .tmux = .{} };
}

pub fn threadExit(self: *Tmux, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .tmux);
    log.info("tmux backend thread exit pane_id={}", .{self.pane_id});

    // Unregister the renderer mutex and wake callback from the viewer pane so
    // the gateway stops touching memory that's about to be freed with this child
    // surface. `detachRenderer` holds a keep-alive ref across the whole detach,
    // flushes the renderer, clears the handshake, DRAINS any in-flight gateway
    // access (a gateway that loaded the mutex pointer just before the clear), and
    // then releases its hold — which performs the final reap if this pane is an
    // orphan whose viewer is gone. After it returns no gateway or renderer is
    // mid-access of this pane, so the child surface can free its renderer_state
    // (mutex + wake target) without a use-after-free. `pane` may be freed by the
    // call; do not touch it afterward. See id=viewer-renderer-users-drain /
    // id=viewer-detach-hold.
    if (self.viewer_pane) |pane| {
        pane.detachRenderer();
    }
}

/// Wake callback registered on the viewer pane (see `Viewer.Pane.wake_fn`).
/// `ctx` is this child surface's `renderer_wakeup` async handle; notifying it
/// wakes the child's renderer thread to draw the freshly-written pane content.
/// Safe to call from the viewer's (parent gateway) IO thread because
/// `xev.Async` is purpose-built for cross-thread notification.
fn wakeRenderer(ctx: ?*anyopaque) void {
    // Null-tolerant: a concurrent threadExit may have cleared wake_ctx between
    // the gateway's wake_fn load and this call. `Pane.detachRenderer` clears
    // wake_fn before wake_ctx, so the gateway usually skips entirely, but guard
    // here too rather than deref a null/torn context.
    const wakeup: *xev.Async = @ptrCast(@alignCast(ctx orelse return));
    wakeup.notify() catch {};
}

/// Focus gained/lost notification. When a Ghostty surface backed by a
/// tmux pane gains focus, send `select-pane` to tell tmux which pane
/// is active. This keeps tmux's active pane in sync with Ghostty's
/// focused surface.
///
/// The feedback loop (select-pane → %window-pane-changed → set_focus →
/// grabFocus → focusCallback) is naturally broken by the deduplication
/// guard in Surface.focusCallback: if the surface is already focused,
/// the callback is a no-op.
pub fn focusGained(
    self: *Tmux,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    assert(td.backend == .tmux);

    // Only send select commands when this surface gains focus.
    // Losing focus is a no-op — the pane that gains focus will
    // send its own select-pane/select-window.
    if (!focused) return;
    self.selectWindow();
    self.selectPane();
}

/// Send a `select-pane` command to tmux targeting this backend's pane.
fn selectPane(self: *Tmux) void {
    var buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "select-pane -t %{d}\n", .{
        self.pane_id,
    }) catch |err| {
        log.warn("select-pane command too large for buffer err={}", .{err});
        return;
    };

    self.control_writer.write(cmd) catch |err| {
        log.warn("failed to send select-pane err={}", .{err});
    };
}

/// Send a `select-window` command to tmux targeting this backend's
/// window. This ensures tmux's active window matches the Ghostty tab
/// that received focus, which is necessary for multi-window sessions
/// where switching tabs must also switch the tmux current window.
fn selectWindow(self: *Tmux) void {
    var buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "select-window -t @{d}\n", .{
        self.window_id,
    }) catch |err| {
        log.warn("select-window command too large for buffer err={}", .{err});
        return;
    };

    self.control_writer.write(cmd) catch |err| {
        log.warn("failed to send select-window err={}", .{err});
    };
}

/// Notify the tmux backend of a terminal resize. This sends a
/// `resize-pane` command to tmux via the control connection.
///
/// Errors from the ControlWriter are propagated to the caller so that
/// a dead control channel is not silently hidden.
pub fn resize(
    self: *Tmux,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) ControlWriter.WriteError!void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;

    // Format and send a resize-pane command. tmux resize-pane uses
    // -x for width (columns) and -y for height (rows).
    var buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "resize-pane -t %{d} -x {d} -y {d}\n", .{
        self.pane_id,
        grid_size.columns,
        grid_size.rows,
    }) catch |err| {
        log.warn("resize command too large for buffer err={}", .{err});
        return;
    };

    try self.control_writer.write(cmd);
}

/// Forward a raw command to the tmux control mode connection.
/// This is the IO-thread entry point for commands that originate from
/// user keybindings (split-window, kill-pane, etc.) and are queued via
/// the `tmux_command` termio message. The command must include a
/// trailing newline since tmux control mode is line-oriented.
pub fn tmuxCommand(self: *Tmux, cmd: []const u8) void {
    self.control_writer.write(cmd) catch |err| {
        log.warn("failed to send tmux command err={}", .{err});
    };
}

/// Write user input to the tmux pane. Input bytes are formatted as
/// `send-keys -H` commands with hex-encoded key values, targeting this
/// backend's pane ID.
///
/// Format: `send-keys -H -t %{pane_id} {hex bytes...}\n`
///
/// The `-H` flag tells tmux to interpret the arguments as hex byte
/// values, which is the most reliable way to send arbitrary data
/// including control characters and escape sequences.
///
/// Large inputs (e.g. a 10KB paste) are split into multiple send-keys
/// commands of at most `max_send_keys_bytes` *input* bytes each (before
/// hex encoding). While modern tmux (3.x) has no hard command-length
/// limit in control mode, chunking avoids blocking the control channel
/// with a single massive command and maintains compatibility with older
/// tmux versions.
pub fn queueWrite(
    self: *Tmux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    assert(td.backend == .tmux);
    if (data.len == 0) return;

    // We need to handle linefeed mode: replace \r with \r\n in the
    // data before hex-encoding it.
    const effective_data = if (!linefeed) data else blk: {
        // Count how many \r bytes we need to expand
        var cr_count: usize = 0;
        for (data) |b| {
            if (b == '\r') cr_count += 1;
        }
        if (cr_count == 0) break :blk data;

        const expanded = try alloc.alloc(u8, data.len + cr_count);
        var j: usize = 0;
        for (data) |b| {
            expanded[j] = b;
            j += 1;
            if (b == '\r') {
                expanded[j] = '\n';
                j += 1;
            }
        }
        break :blk expanded[0..j];
    };
    defer if (linefeed and effective_data.ptr != data.ptr) {
        alloc.free(effective_data);
    };

    // Allocate a reusable buffer large enough for one max-sized chunk.
    // Per chunk: prefix + id_digits + space + hex(max_send_keys_bytes) + newline
    const prefix = "send-keys -H -t %";
    const id_digits = digitCount(self.pane_id);
    const max_hex_len = max_send_keys_bytes * 3 - 1; // "XX " per byte, last byte "XX"
    const max_cmd_len = prefix.len + id_digits + 1 + max_hex_len + 1;

    const buf = try alloc.alloc(u8, max_cmd_len);
    defer alloc.free(buf);

    // Send chunks of effective_data as separate send-keys commands.
    var offset: usize = 0;
    while (offset < effective_data.len) {
        const remaining = effective_data.len - offset;
        const chunk_len = @min(remaining, max_send_keys_bytes);
        const chunk = effective_data[offset..][0..chunk_len];

        const cmd_len = writeSendKeysCmd(buf, prefix, self.pane_id, id_digits, chunk);
        try self.control_writer.write(buf[0..cmd_len]);

        offset += chunk_len;
    }
}

/// Maximum number of input bytes per send-keys command. Each input
/// byte becomes 3 hex characters ("XX "), so 1024 bytes produce a
/// command of ~3.1KB — well within any practical limit.
const max_send_keys_bytes = 1024;

/// Format a `send-keys -H -t %<id> <hex>...\n` command into `buf`.
/// Returns the number of bytes written. The caller must ensure `buf`
/// is large enough for the given `chunk` (see `queueWrite` allocation).
fn writeSendKeysCmd(
    buf: []u8,
    prefix: []const u8,
    pane_id: usize,
    id_digits: usize,
    chunk: []const u8,
) usize {
    var pos: usize = 0;

    // Write the prefix
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    // Write the pane ID
    const id_slice = std.fmt.bufPrint(buf[pos..][0..id_digits], "{d}", .{pane_id}) catch unreachable;
    pos += id_slice.len;

    // Space separator
    buf[pos] = ' ';
    pos += 1;

    // Write hex-encoded bytes
    const hex_chars = "0123456789ABCDEF";
    for (chunk, 0..) |byte, i| {
        buf[pos] = hex_chars[byte >> 4];
        pos += 1;
        buf[pos] = hex_chars[byte & 0x0F];
        pos += 1;
        if (i < chunk.len - 1) {
            buf[pos] = ' ';
            pos += 1;
        }
    }

    // Trailing newline
    buf[pos] = '\n';
    pos += 1;

    return pos;
}

/// No child process to report on — this is a no-op.
pub fn childExitedAbnormally(
    self: *Tmux,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// Thread-local data for the tmux backend. Currently empty — the tmux
/// backend does not participate in the xev event loop directly.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        self.* = undefined;
    }
};

/// Count the number of decimal digits in a usize value.
fn digitCount(n: usize) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

/// A test mock for ControlWriter that captures all written commands.
const TestControlWriter = struct {
    alloc: Allocator,
    commands: std.ArrayList([]const u8) = .empty,

    fn init(alloc: Allocator) TestControlWriter {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *TestControlWriter) void {
        for (self.commands.items) |cmd| {
            self.alloc.free(cmd);
        }
        self.commands.deinit(self.alloc);
    }

    fn controlWriter(self: *TestControlWriter) ControlWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *anyopaque, data: []const u8) ControlWriter.WriteError!void {
        const self: *TestControlWriter = @ptrCast(@alignCast(context));
        const copy = self.alloc.dupe(u8, data) catch return error.WriteFailed;
        self.commands.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return error.WriteFailed;
        };
    }

    fn lastCommand(self: *const TestControlWriter) ?[]const u8 {
        if (self.commands.items.len == 0) return null;
        return self.commands.items[self.commands.items.len - 1];
    }
};

/// A test mock for ControlWriter that always returns ConnectionClosed.
/// Used to verify that callers handle write failures gracefully without
/// corrupting internal state.
const FailingControlWriter = struct {
    fn controlWriter() ControlWriter {
        return .{
            .context = undefined,
            .writeFn = &writeFn,
        };
    }

    fn writeFn(_: *anyopaque, _: []const u8) ControlWriter.WriteError!void {
        return error.ConnectionClosed;
    }
};

/// Create a minimal Termio.ThreadData with .tmux backend for testing.
/// Only the `backend` field is meaningfully set; other fields are
/// undefined since the tmux backend does not access them in queueWrite.
fn testThreadData() termio.Termio.ThreadData {
    var td: termio.Termio.ThreadData = undefined;
    td.backend = .{ .tmux = .{} };
    return td;
}

test "init sets pane_id and initial sizes" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    const tmux = Tmux.init(.{
        .pane_id = 42,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    try testing.expectEqual(@as(usize, 42), tmux.pane_id);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.rows);
}

test "resize sends resize-pane command" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 5,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 80, .rows = 24 },
        .{ .width = 800, .height = 600 },
    );

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("resize-pane -t %5 -x 80 -y 24\n", writer.lastCommand().?);

    // Verify internal state was updated
    try testing.expectEqual(@as(renderer.GridSize.Unit, 80), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 24), tmux.grid_size.rows);
}

test "resize with large pane_id" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 12345,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 120, .rows = 40 },
        .{ .width = 1200, .height = 800 },
    );

    try testing.expectEqualStrings("resize-pane -t %12345 -x 120 -y 40\n", writer.lastCommand().?);
}

test "resize consecutive calls track latest dimensions" {
    // Verify that multiple resize calls correctly update internal state
    // and emit one command per call. The coalesce timer in Thread.zig
    // handles deduplication at the IO thread level — the backend itself
    // must faithfully emit every resize it receives.
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 3,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // First resize
    try tmux.resize(
        .{ .columns = 80, .rows = 24 },
        .{ .width = 800, .height = 480 },
    );
    // Second resize (window grew)
    try tmux.resize(
        .{ .columns = 120, .rows = 40 },
        .{ .width = 1200, .height = 800 },
    );
    // Third resize (window shrunk)
    try tmux.resize(
        .{ .columns = 60, .rows = 15 },
        .{ .width = 600, .height = 300 },
    );

    // All three commands must have been emitted
    try testing.expectEqual(@as(usize, 3), writer.commands.items.len);
    try testing.expectEqualStrings("resize-pane -t %3 -x 80 -y 24\n", writer.commands.items[0]);
    try testing.expectEqualStrings("resize-pane -t %3 -x 120 -y 40\n", writer.commands.items[1]);
    try testing.expectEqualStrings("resize-pane -t %3 -x 60 -y 15\n", writer.commands.items[2]);

    // Internal state must reflect the latest resize
    try testing.expectEqual(@as(renderer.GridSize.Unit, 60), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 15), tmux.grid_size.rows);
    try testing.expectEqual(@as(u32, 600), tmux.screen_size.width);
    try testing.expectEqual(@as(u32, 300), tmux.screen_size.height);
}

test "resize updates state even when control writer fails" {
    // The resize method updates grid_size and screen_size before
    // attempting the control_writer.write call. This ensures local
    // state remains consistent even if the control connection is dead.
    var tmux = Tmux.init(.{
        .pane_id = 99,
        .window_id = 0,
        .control_writer = FailingControlWriter.controlWriter(),
    });

    // Verify initial state is zero
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.rows);

    // resize should propagate the ConnectionClosed error
    try testing.expectError(error.ConnectionClosed, tmux.resize(
        .{ .columns = 100, .rows = 50 },
        .{ .width = 1000, .height = 500 },
    ));

    // But state must still be updated (write happens after state update)
    try testing.expectEqual(@as(renderer.GridSize.Unit, 100), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 50), tmux.grid_size.rows);
    try testing.expectEqual(@as(u32, 1000), tmux.screen_size.width);
    try testing.expectEqual(@as(u32, 500), tmux.screen_size.height);
}

test "resize tracks screen_size alongside grid_size" {
    // Verify that screen_size (pixel dimensions) is tracked alongside
    // grid_size (cell dimensions). Both are needed: grid_size for the
    // resize-pane command, screen_size for pixel-level state in
    // Termio.resize (terminal.width_px / height_px).
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 1,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 132, .rows = 43 },
        .{ .width = 1584, .height = 774 },
    );

    // Grid size
    try testing.expectEqual(@as(renderer.GridSize.Unit, 132), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 43), tmux.grid_size.rows);
    // Screen size (pixel dimensions)
    try testing.expectEqual(@as(u32, 1584), tmux.screen_size.width);
    try testing.expectEqual(@as(u32, 774), tmux.screen_size.height);
    // Command uses grid dimensions, not pixel dimensions
    try testing.expectEqualStrings("resize-pane -t %1 -x 132 -y 43\n", writer.lastCommand().?);
}

test "queueWrite formats send-keys with hex encoding" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 2,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // "ls\r" = 0x6C 0x73 0x0D
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "ls\r", false);

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("send-keys -H -t %2 6C 73 0D\n", writer.lastCommand().?);
}

test "queueWrite single byte" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 0,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "a", false);

    try testing.expectEqualStrings("send-keys -H -t %0 61\n", writer.lastCommand().?);
}

test "queueWrite escape sequence" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 10,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // Up arrow: ESC [ A = 0x1B 0x5B 0x41
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "\x1B[A", false);

    try testing.expectEqualStrings("send-keys -H -t %10 1B 5B 41\n", writer.lastCommand().?);
}

test "queueWrite with linefeed mode" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 3,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // "ab\rcd" with linefeed=true should become "ab\r\ncd"
    // hex: 61 62 0D 0A 63 64
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "ab\rcd", true);

    try testing.expectEqualStrings("send-keys -H -t %3 61 62 0D 0A 63 64\n", writer.lastCommand().?);
}

test "queueWrite empty data is no-op" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 1,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "", false);

    try testing.expectEqual(@as(usize, 0), writer.commands.items.len);
}

test "queueWrite large pane_id" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 99999,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "X", false);

    try testing.expectEqualStrings("send-keys -H -t %99999 58\n", writer.lastCommand().?);
}

test "queueWrite chunks large input into multiple commands" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 5,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // Create input slightly larger than one chunk (max_send_keys_bytes + 1).
    const input_len = max_send_keys_bytes + 1;
    const input = try alloc.alloc(u8, input_len);
    defer alloc.free(input);
    @memset(input, 'A'); // 0x41

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, false);

    // Should produce exactly 2 commands: one full chunk + 1 remaining byte.
    try testing.expectEqual(@as(usize, 2), writer.commands.items.len);

    // First command: max_send_keys_bytes worth of "41" hex values
    const cmd1 = writer.commands.items[0];
    try testing.expect(std.mem.startsWith(u8, cmd1, "send-keys -H -t %5 "));
    try testing.expect(std.mem.endsWith(u8, cmd1, "\n"));

    // Second command: 1 byte
    const cmd2 = writer.commands.items[1];
    try testing.expectEqualStrings("send-keys -H -t %5 41\n", cmd2);
}

test "queueWrite exactly max_send_keys_bytes is single command" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 0,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    const input = try alloc.alloc(u8, max_send_keys_bytes);
    defer alloc.free(input);
    @memset(input, 'B'); // 0x42

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, false);

    // Exactly at the limit — should be a single command.
    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
}

test "queueWrite large input with linefeed mode chunks correctly" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 1,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // Create input that, after linefeed expansion, exceeds one chunk.
    // Fill with \r so each byte becomes \r\n (doubles the size).
    const input_len = max_send_keys_bytes / 2 + 1;
    const input = try alloc.alloc(u8, input_len);
    defer alloc.free(input);
    @memset(input, '\r');

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, true);

    // After expansion: (max_send_keys_bytes / 2 + 1) * 2 = max_send_keys_bytes + 2
    // Should produce 2 commands.
    try testing.expectEqual(@as(usize, 2), writer.commands.items.len);
}

test "queueWrite multiple full chunks" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // 3 full chunks exactly
    const input_len = max_send_keys_bytes * 3;
    const input = try alloc.alloc(u8, input_len);
    defer alloc.free(input);
    @memset(input, 'C');

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, false);

    try testing.expectEqual(@as(usize, 3), writer.commands.items.len);
}

test "deinit resets state" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    tmux.deinit();
    // After deinit, the struct is undefined — we just verify it
    // doesn't crash.
}

test "digitCount" {
    try testing.expectEqual(@as(usize, 1), digitCount(0));
    try testing.expectEqual(@as(usize, 1), digitCount(1));
    try testing.expectEqual(@as(usize, 1), digitCount(9));
    try testing.expectEqual(@as(usize, 2), digitCount(10));
    try testing.expectEqual(@as(usize, 2), digitCount(99));
    try testing.expectEqual(@as(usize, 3), digitCount(100));
    try testing.expectEqual(@as(usize, 5), digitCount(12345));
    try testing.expectEqual(@as(usize, 5), digitCount(99999));
}

test "ParentWriter routes commands through mailbox" {
    const alloc = testing.allocator;

    // Create a real SPSC mailbox
    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
    };
    const writer = parent_writer.controlWriter();

    // Write a command through the ParentWriter
    try writer.write("list-windows\n");

    // Verify the command was queued in the mailbox
    const msg = mailbox.spsc.queue.pop() orelse {
        return error.TestUnexpectedResult;
    };

    // The message should be a write_small or write_alloc depending on size.
    // "list-windows\n" is 14 bytes, which fits in write_small.
    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("list-windows\n", data);

    // Clean up alloc data if it was heap-allocated
    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}

test "ParentWriter handles large commands" {
    const alloc = testing.allocator;

    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
    };
    const writer = parent_writer.controlWriter();

    // Write a command larger than WriteReq.Small capacity (38 bytes)
    const large_cmd = "send-keys -H -t %12345 41 42 43 44 45 46 47 48\n";
    try writer.write(large_cmd);

    const msg = mailbox.spsc.queue.pop() orelse {
        return error.TestUnexpectedResult;
    };

    // Large command should use write_alloc
    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(large_cmd, data);

    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}

test "ParentWriter used as backend ControlWriter" {
    // Verify that ParentWriter integrates with the Tmux backend:
    // create a Tmux backend with a ParentWriter, call resize, and
    // confirm the resize-pane command reaches the mailbox.
    const alloc = testing.allocator;

    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
    };

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .window_id = 0,
        .control_writer = parent_writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 100, .rows = 30 },
        .{ .width = 1000, .height = 600 },
    );

    const msg = mailbox.spsc.queue.pop() orelse {
        return error.TestUnexpectedResult;
    };

    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("resize-pane -t %7 -x 100 -y 30\n", data);

    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}

test "tmux relay: WriteReq fits small tmux commands inline" {
    // Verify that typical tmux commands (< 255 bytes) produce a
    // WriteReq.small variant, confirming the surface-level WriteReq
    // handles them without allocation.
    const alloc = testing.allocator;
    const SurfaceWriteReq = apprt.surface.Message.WriteReq;

    // A typical resize-pane command (~30 bytes)
    const cmd: []const u8 = "resize-pane -t %5 -x 80 -y 24\n";
    const req = try SurfaceWriteReq.init(alloc, cmd);
    try testing.expect(req == .small);
    try testing.expectEqualStrings(cmd, req.slice());
}

test "tmux relay: WriteReq allocates for large commands" {
    // Verify that commands exceeding 255 bytes (surface WriteReq.Small
    // capacity) use the alloc variant.
    const alloc = testing.allocator;
    const SurfaceWriteReq = apprt.surface.Message.WriteReq;

    // Construct a send-keys command larger than 255 bytes
    const large_cmd: []const u8 = "send-keys -H -t %12345 " ++ "41 " ** 100 ++ "\n";
    const req = try SurfaceWriteReq.init(alloc, large_cmd);
    defer req.deinit();
    try testing.expect(req == .alloc);
    try testing.expectEqualStrings(large_cmd, req.slice());
}

test "tmux relay: conversion preserves data across WriteReq size boundaries" {
    // Verify the full relay conversion: surface WriteReq.small (up to
    // 255 bytes) -> termio.Message.writeReq -> write_small (<=38) or
    // write_alloc (>38). This tests the size mismatch handling in the
    // Surface.handleMessage(.tmux_write_command) path.
    const alloc = testing.allocator;
    const SurfaceWriteReq = apprt.surface.Message.WriteReq;

    // Case 1: Command fits in BOTH surface small (255) and termio small (38)
    {
        const cmd: []const u8 = "list-windows\n"; // 14 bytes
        const surface_req = try SurfaceWriteReq.init(alloc, cmd);
        try testing.expect(surface_req == .small);

        // Simulate relay: extract data, convert to termio message
        const io_msg = try termio.Message.writeReq(alloc, surface_req.slice());
        try testing.expect(io_msg == .write_small);
        const data = switch (io_msg) {
            .write_small => |s| s.data[0..s.len],
            else => unreachable,
        };
        try testing.expectEqualStrings(cmd, data);
    }

    // Case 2: Command fits in surface small (255) but NOT termio small (38)
    {
        const cmd: []const u8 = "send-keys -H -t %12345 41 42 43 44 45 46 47 48\n"; // 49 bytes
        try testing.expect(cmd.len > 38);
        try testing.expect(cmd.len <= 255);

        const surface_req = try SurfaceWriteReq.init(alloc, cmd);
        try testing.expect(surface_req == .small);

        // Simulate relay: this must produce write_alloc, not write_small
        const io_msg = try termio.Message.writeReq(alloc, surface_req.slice());
        try testing.expect(io_msg == .write_alloc);
        switch (io_msg) {
            .write_alloc => |a| {
                try testing.expectEqualStrings(cmd, a.data);
                a.alloc.free(a.data);
            },
            else => unreachable,
        }
    }
}

test "selectPane sends select-pane command" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    tmux.selectPane();

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("select-pane -t %7\n", writer.lastCommand().?);
}

test "selectPane with large pane_id" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 99999,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    tmux.selectPane();

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("select-pane -t %99999\n", writer.lastCommand().?);
}

test "selectWindow sends select-window command" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 3,
        .window_id = 5,
        .control_writer = writer.controlWriter(),
    });

    tmux.selectWindow();

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("select-window -t @5\n", writer.lastCommand().?);
}

test "selectWindow with large window_id" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 0,
        .window_id = 99999,
        .control_writer = writer.controlWriter(),
    });

    tmux.selectWindow();

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("select-window -t @99999\n", writer.lastCommand().?);
}

test "tmuxCommand sends raw command to control writer" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 3,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    tmux.tmuxCommand("split-window -h -t %3\n");

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("split-window -h -t %3\n", writer.lastCommand().?);
}
