// ROOTSHELL-TMUX: fork-owned tmux control-mode viewer. This entire src/terminal/tmux_cc/
// directory is fork-owned and was relocated off the upstream-shared src/terminal/tmux/
// path so upstream's experimental tmux parser can never 3-way-merge against it. On
// rebase, take OUR version wholesale; if upstream edits src/terminal/tmux/*, keep them
// deleted. See docs/tmux-control-mode-fork.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../size.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const color = @import("../color.zig");
const TerminalStream = @import("../stream_terminal.zig").Stream;
const TerminalStreamHandler = @import("../stream_terminal.zig").Handler;
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");

const log = std.log.scoped(.terminal_tmux_viewer);

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// Number of bytes of output buffered server-side before tmux pauses the
/// pane. Sent as `-f pause-after=<N>` in the initial `refresh-client`
/// command. A low value keeps latency tight but increases pause/continue
/// churn; 200 is empirically a good balance for interactive shells.
const PAUSE_AFTER_BYTES = 200;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
///
/// ## Threading Model
///
/// The Viewer is **single-threaded**: all methods are called exclusively
/// from the parent surface's I/O thread (the termio thread that owns the
/// control mode connection). There are no internal mutexes or atomics.
///
/// Cross-thread coordination occurs at one point: each `Pane` holds an
/// optional `renderer_mutex` that, when non-null, points to the child
/// surface's `renderer_state.mutex`. The viewer acquires this mutex in
/// all terminal-write paths (`receivedOutput`, `receivedPaneHistory`,
/// `receivedPaneVisible`, `receivedPaneState`) to coordinate with the
/// child's renderer thread, which reads from the same `Terminal` under
/// this mutex.
///
/// The `renderer_mutex` lifecycle is managed externally by `Tmux.zig`:
/// - Set during `threadEnter` (child surface's I/O thread has started,
///   renderer is about to begin reading the terminal).
/// - Cleared during `threadExit` (child is shutting down, renderer will
///   no longer read).
///
/// When `renderer_mutex` is null (before a child surface attaches or
/// after it detaches), no locking is needed because no other thread
/// is reading the terminal.
///
/// ## Viewer Lifecycle
///
/// The viewer progresses through several states from initial connection
/// to steady-state operation. Here is the full flow:
///
/// ```
///                              ┌─────────────────────────────────────────────┐
///                              │           TMUX CONTROL MODE START           │
///                              │         (DCS 1000p received by host)        │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │              startup                        │
///                              │                                             │
///                              │  Wait for both:                             │
///                              │  1. Initial %begin/%end block (response to  │
///                              │     the attach command)                     │
///                              │  2. %session-changed notification (gives    │
///                              │     us the session ID)                      │
///                              │  Either can arrive first.                   │
///                              └─────────────────┬───────────────────────────┘
///                                                │ both received
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           command_queue                     │
///                              │                                             │
///                              │  Main operating state. Process commands     │
///                              │  sequentially and handle notifications.     │
///                              └─────────────────────────────────────────────┘
///                                                │
///                    ┌───────────────────────────┼───────────────────────────┐
///                    │                           │                           │
///                    ▼                           ▼                           ▼
///     ┌──────────────────────────┐ ┌──────────────────────────┐ ┌────────────────────────┐
///     │     tmux_version         │ │     list_windows         │ │   %output / %layout-   │
///     │                          │ │                          │ │   change / etc.        │
///     │  Query tmux version for  │ │  Get all windows in the  │ │                        │
///     │  compatibility checks.   │ │  current session.        │ │  Handle live updates   │
///     └──────────────────────────┘ └────────────┬─────────────┘ │  from tmux server.     │
///                                               │               └────────────────────────┘
///                                               ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          syncLayouts                        │
///                              │                                             │
///                              │  For each window, parse layout and sync     │
///                              │  panes. New panes trigger capture commands. │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                    ┌───────────────────────────┴───────────────────────────┐
///                    │                  For each new pane:                   │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (primary screen)     │                            │     (primary screen)     │
///     │                          │                            │                          │
///     │  Capture scrollback      │                            │  Capture visible area    │
///     │  history into terminal.  │                            │  into terminal.          │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (alternate screen)   │                            │     (alternate screen)   │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    └───────────────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          pane_state                         │
///                              │                                             │
///                              │  Query cursor position, cursor style,       │
///                              │  and alternate screen mode for all panes.   │
///                              └─────────────────────────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │        READY FOR OPERATION                  │
///                              │                                             │
///                              │  Panes are populated with content. The      │
///                              │  viewer handles %output for live updates,   │
///                              │  %layout-change for pane changes, and       │
///                              │  %session-changed for session switches.     │
///                              └─────────────────────────────────────────────┘
/// ```
///
/// ## Error Handling
///
/// At any point, if an unrecoverable error occurs or tmux sends `%exit`,
/// the viewer transitions to the `defunct` state and emits an `.exit` action.
///
/// ## Session Changes
///
/// When `%session-changed` is received during `command_queue` state, the
/// viewer resets itself completely: clears all windows/panes, emits an
/// empty windows action, and restarts the `list_windows` flow for the new
/// session.
///
pub const Viewer = struct {
    /// Allocator used for all internal state.
    alloc: Allocator,

    /// Current state of the state machine.
    state: State,

    /// During startup, tracks whether we've received the initial
    /// %begin/%end block. Once both this and startup_got_session are
    /// set, we transition to command_queue. Only meaningful in .startup state.
    startup_got_block: bool,

    /// During startup, tracks whether we've received %session-changed.
    /// Only meaningful in .startup state.
    startup_got_session: bool,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The current session name. Stored on the windows arena and
    /// valid until the next list-windows refresh. Empty if not yet
    /// known (session name is set from `%session-changed` on attach
    /// and updated via `%session-renamed`).
    session_name: []const u8,

    /// The tmux server version string (e.g., "3.5a"). We capture this
    /// on startup because it will allow us to change behavior between
    /// versions as necessary.
    tmux_version: []const u8,

    /// Current control client size (columns and rows). Sent to tmux
    /// via `refresh-client -C` on startup so tmux knows our display
    /// dimensions. Updated externally via `setClientSize` when the
    /// parent terminal resizes.
    client_cols: size.CellCountInt,
    client_rows: size.CellCountInt,

    /// Themed colors applied to each pane terminal so default-background cells
    /// match the app theme (the viewer-owner/gateway terminal's colors) instead
    /// of the built-in dark default. Defaults to `.default` (unset) so tests and
    /// the plain `init` are unchanged; the stream handler sets this to the
    /// gateway terminal's colors right after creating the viewer, and
    /// `sessionChanged` carries it forward to the replacement viewer.
    colors: Terminal.Colors = .default,

    /// Whether a command has been sent to tmux and we're awaiting its
    /// `%begin`/`%end` response block. This disambiguates "queue is
    /// empty because nothing was queued" from "queue has entries but
    /// the first one was already sent." Without this, externally-queued
    /// commands (e.g. from `setClientSize`) that land in an empty queue
    /// would be mistaken for an already-sent in-flight command.
    command_in_flight: bool,

    /// The list of commands we've sent that we want to send and wait
    /// for a response for. We only send one command at a time just
    /// to avoid any possible confusion around ordering.
    command_queue: CommandQueue,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// Arena that owns all window and layout data. Layout trees (allocated
    /// by `Layout.parseWithChecksum`) and the window structs' layout
    /// pointers all live here. Reset-and-rebuild on every topology change
    /// (`receivedListWindows`, `layoutChanged`, `sessionChanged`).
    windows_arena: ArenaAllocator.State,

    /// The panes in the current session, mapped by pane ID.
    panes: PanesMap,

    /// Panes pruned by tmux (e.g. the pane process exited) while a child
    /// surface's renderer was still attached (`renderer_mutex != null`). We
    /// must NOT free such a pane's terminal yet: the child surface renders
    /// from it on its own renderer thread, and freeing it out from under that
    /// thread is a use-after-free. We retire the pane here and free it in
    /// `reapRetiredPanes` once the child detaches (its `threadExit` clears
    /// `renderer_mutex`).
    retired_panes: std.ArrayListUnmanaged(*Pane) = .empty,

    /// Active-pane title (`#{pane_title}` / `#T`) per window id, fed by the
    /// `@*` pane_title format subscription (see `title_subscription_name`).
    /// Values are owned on `self.alloc` — NOT the windows arena — so they
    /// survive list-windows rebuilds (tmux only re-sends a subscription value
    /// when it changes, so we must retain the last one) and stay bounded to
    /// one string per window even when a pane rewrites its title rapidly.
    /// Empty/missing means "no pane title; fall back to the window name".
    /// Freed on replace and on deinit.
    pane_titles: PaneTitlesMap = .empty,

    /// Whether the pane-title subscription command has been queued yet. We
    /// queue it once, after the first list-windows' capture sequence, so it
    /// trails (rather than interrupts) the startup command flow. The tmux
    /// subscription is client-scoped and persists across session changes; a
    /// replacement viewer (new session) starts false and re-queues it, which
    /// tmux deduplicates by name.
    title_subscription_queued: bool = false,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    pub const CommandQueue = CircBuf(Command, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, *Pane);
    // ROOTSHELL-TMUX (id=viewer-pane-titles-map): active-pane title (#T) per
    // window id, fed by the `@*:#{pane_title}` subscription. Named so the
    // topology snapshot can resolve the same title precedence (see
    // resolveWindowTitle / Surface_tmux planTmuxReconcile).
    pub const PaneTitlesMap = std.AutoHashMapUnmanaged(usize, []u8);

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never reuses window IDs within a server process lifetime.
        windows: []const Window,

        /// The active pane changed in tmux. The caller should update
        /// focus to the specified window and pane. This is emitted in
        /// response to `%window-pane-changed` notifications from tmux.
        ///
        /// Rationale for tmux→Ghostty focus sync: Mitchell's upstream
        /// viewer ignores `%window-pane-changed` because "we handle our
        /// own focus." However, in multi-client scenarios (SSH pair
        /// programming, automation scripts, `tmux select-pane` from
        /// another terminal), the active pane can change externally.
        /// Without this sync, Ghostty's visible focus would diverge
        /// from tmux's actual active pane. We keep bidirectional focus
        /// sync (Ghostty→tmux via `select-pane`, tmux→Ghostty via
        /// this action) to stay consistent in these real-world cases.
        focus: struct {
            window_id: usize,
            pane_id: usize,
        },

        /// A tmux window was renamed. The caller should update the
        /// tab title for the given window ID.
        title: struct {
            window_id: usize,
            /// Window name, stored on the viewer's windows arena.
            /// Valid until the next list-windows refresh.
            name: []const u8,
        },

        /// The tmux session was renamed. The caller should update the
        /// Ghostty window title.
        session_title: struct {
            /// Session name, stored on the viewer's windows arena.
            /// Valid until the next list-windows refresh.
            name: []const u8,
        },

        /// A pane's pause state changed. When `paused` is true, tmux
        /// has stopped sending `%output` for this pane (output is
        /// buffered server-side). The caller should send
        /// `refresh-client -A '%<pane_id>:continue'` to resume, e.g.
        /// when the user switches focus to the paused pane.
        pane_paused: struct {
            pane_id: usize,
            paused: bool,
        },

        /// A pane's mode changed in tmux. This is emitted in response
        /// to `%pane-mode-changed` notifications after querying the
        /// actual mode via `display-message`. The caller can use this
        /// to show visual indicators (e.g., copy mode overlay).
        pane_mode_changed: struct {
            pane_id: usize,
            mode: PaneMode,
        },

        /// A message from the tmux server (via `display-message` or
        /// server-level informational/error messages). The runtime can
        /// surface this in a status bar, toast, or log view.
        message: struct {
            text: []const u8,
        },

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
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

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,
    };

    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        layout: Layout,
        /// Window name from tmux (e.g., "bash", "vim"). Stored on the
        /// shared windows arena and valid until the next list-windows
        /// refresh. Empty slice if not yet known.
        name: []const u8 = "",
    };

    pub const Pane = struct {
        terminal: Terminal,
        stream: TerminalStream,

        /// Mutex protecting concurrent access to `terminal`. This is set
        /// by the child surface's tmux backend during `threadEnter` to
        /// point at the child's `renderer_state.mutex`. Before it is set
        /// (null), no child renderer is reading, so no locking is needed.
        ///
        /// The viewer acquires this mutex in all terminal-write paths
        /// (`receivedOutput`, `receivedPaneHistory`, `receivedPaneVisible`,
        /// `receivedPaneState`) to coordinate with the child surface's
        /// renderer thread.
        renderer_mutex: ?*std.Thread.Mutex = null,

        /// Opaque wake callback registered by the child surface's tmux
        /// backend in `Tmux.threadEnter` (cleared in `threadExit`). The viewer
        /// invokes it after writing to `terminal` so the child surface's
        /// renderer thread is woken to draw the new content. The child's own
        /// IO thread (the tmux backend) never processes this output, so
        /// without an explicit wake the pane would not repaint until some
        /// unrelated event. Kept opaque (a fn pointer + context) so the
        /// terminal layer stays decoupled from the IO/renderer/xev layer.
        wake_ctx: ?*anyopaque = null,
        wake_fn: ?*const fn (?*anyopaque) void = null,

        /// True from the moment this pane's terminal is created (io thread,
        /// `initLayout`) until a child surface attaches its renderer
        /// (`Tmux.threadEnter` clears it). While true, a child surface for this
        /// pane is "en route": the reconcile op has been (or will be) emitted but
        /// the child hasn't bound yet, so `renderer_mutex` is still null. The
        /// viewer must NOT free the pane in this window or the child later binds
        /// to freed memory (the `tmux -CC attach` / `%session-changed` crash).
        /// All free paths treat this like `renderer_mutex != null`. Set and read
        /// on the io thread; cleared on the child io thread right after
        /// `renderer_mutex` is set, so a free path always sees one or the other.
        pending_attach: bool = false,

        /// Whether this pane has been fully initialized with captured
        /// content and terminal state from tmux. Output notifications
        /// are suppressed until this is true to avoid displaying
        /// partial/stale data before the capture-pane sequence completes.
        initialized: bool = false,

        /// Whether this pane is currently paused by tmux. When true,
        /// tmux is buffering output server-side and not sending
        /// `%output` for this pane. Set by `%pause` notification,
        /// cleared by `%continue`.
        paused: bool = false,

        /// The current mode of this pane as reported by tmux. Updated
        /// via `display-message -p '#{pane_mode}'` queries triggered by
        /// `%pane-mode-changed` notifications.
        mode: PaneMode = .normal,

        /// Query replies generated by this pane's terminal while processing
        /// live `%output` (e.g. kitty-keyboard, DECRQM, OSC 4/12 replies for
        /// queries tmux itself does not answer). Each entry is one complete
        /// reply from a single `write_pty` call. Drained, filtered, and routed
        /// back to the app as `send-keys` after each `%output` feed (see
        /// `flushPaneResponses`). Only `pane.stream` (live output) installs the
        /// router; capture-pane replays use throwaway readonly streams so stale
        /// queries in history never produce replies.
        responses: std.ArrayList([]const u8) = .empty,

        pub fn deinit(self: *Pane, alloc: Allocator) void {
            for (self.responses.items) |chunk| alloc.free(chunk);
            self.responses.deinit(alloc);
            self.stream.deinit();
            self.terminal.deinit(alloc);
        }
    };

    pub const PaneMode = enum {
        /// Normal terminal mode (no special mode active).
        normal,
        /// Copy mode — tmux's scrollback/selection mode.
        copy,
        /// View mode — read-only copy mode (e.g., from `capture-pane -e`).
        view,

        /// Parse a tmux `#{pane_mode}` string into this enum.
        /// Empty string = normal, "copy-mode" = copy, "view-mode" = view.
        /// Unknown mode names are logged and treated as normal.
        pub fn fromString(s: []const u8) PaneMode {
            if (s.len == 0) return .normal;
            if (std.mem.eql(u8, s, "copy-mode")) return .copy;
            if (std.mem.eql(u8, s, "view-mode")) return .view;
            log.info("unknown pane mode: {s}", .{s});
            return .normal;
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(alloc: Allocator, client_cols: size.CellCountInt, client_rows: size.CellCountInt) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        return .{
            .alloc = alloc,
            .state = .startup,
            .startup_got_block = false,
            .startup_got_session = false,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .session_name = "",
            .tmux_version = "",
            .client_cols = client_cols,
            .client_rows = client_rows,
            .command_in_flight = false,
            .command_queue = command_queue,
            .windows = .empty,
            .windows_arena = .{},
            .panes = .empty,
            .action_arena = .{},
            .action_single = undefined,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            self.windows.deinit(self.alloc);
            self.windows_arena.promote(self.alloc).deinit();
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| {
                const pane = kv.value_ptr.*;
                // A child surface's renderer may still point at this pane's
                // terminal (renderer_mutex != null => still attached). The
                // viewer can be deinited while children are alive — tmux's
                // stream_handler frees the viewer synchronously on `%exit`, and
                // `sessionChanged` deinits the old viewer on `%session-changed`,
                // both BEFORE the child pane surfaces have been torn down. Freeing
                // an attached pane's terminal here would UAF that renderer thread
                // (crash in updateFrame/updateExtraRows). Leak it instead: the
                // child later clears renderer_mutex on still-valid memory when it
                // detaches. Detached panes (mutex null) free normally. Also leak
                // en-route panes (pending_attach) whose child has not bound yet.
                if (pane.renderer_mutex != null or pane.pending_attach) continue;
                pane.deinit(self.alloc);
                self.alloc.destroy(pane);
            }
            self.panes.deinit(self.alloc);
        }
        {
            // Free retired panes whose child has already detached; leak any
            // still attached or en route (same reasoning as above).
            for (self.retired_panes.items) |pane| {
                if (pane.renderer_mutex != null or pane.pending_attach) continue;
                pane.deinit(self.alloc);
                self.alloc.destroy(pane);
            }
            self.retired_panes.deinit(self.alloc);
        }
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        {
            var it = self.pane_titles.iterator();
            while (it.next()) |kv| self.alloc.free(kv.value_ptr.*);
            self.pane_titles.deinit(self.alloc);
        }
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Update the stored control client dimensions and queue a
    /// `refresh-client -C WxH` command if we're in the `command_queue`
    /// state. The command will be sent to tmux on the next notification
    /// cycle (pull-based). During startup the initial size is sent as
    /// part of the startup sequence in `tryFinishStartup`, so calling
    /// this before entering `command_queue` only stores the dimensions.
    pub fn setClientSize(
        self: *Viewer,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) void {
        self.client_cols = cols;
        self.client_rows = rows;

        if (self.state == .command_queue) {
            self.queueCommands(&.{.{ .client_size = .{
                .cols = cols,
                .rows = rows,
            } }}) catch {
                log.warn("failed to queue client_size command", .{});
            };
        }
    }

    /// Update the themed colors used for new pane terminals, and re-report
    /// them to tmux for every existing pane so OSC 10/11 queries reflect the
    /// current theme after a config reload. Only the `default` slot is changed
    /// (mirroring how `Termio.changeConfig` applies config colors), so a live
    /// OSC override on the gateway still wins. The report is queued only when
    /// we are in the `command_queue` state and have concrete colors; otherwise
    /// the color update still takes effect for future panes.
    pub fn updateColors(
        self: *Viewer,
        fg: ?color.RGB,
        bg: ?color.RGB,
    ) void {
        if (fg) |c| self.colors.foreground.default = c;
        if (bg) |c| self.colors.background.default = c;

        if (self.state != .command_queue) return;
        const rfg = self.colors.foreground.get() orelse return;
        const rbg = self.colors.background.get() orelse return;
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            // Two separate reports per pane: tmux parses one OSC per report.
            self.queueCommands(&.{
                .{ .pane_color_report = .{ .pane_id = kv.key_ptr.*, .code = 10, .color = rfg } },
                .{ .pane_color_report = .{ .pane_id = kv.key_ptr.*, .code = 11, .color = rbg } },
            }) catch {
                log.warn("failed to queue pane_color_report on theme change", .{});
            };
        }
    }

    /// Format the head command for sending IF it is queued-but-unsent, and
    /// mark it in flight. Returns the formatted command (owned by `arena_alloc`,
    /// including its trailing newline) or null when there is nothing to send.
    ///
    /// This exists because the viewer's command pump is pull-based: the next
    /// queued command is only formatted and emitted inside `next()` when an
    /// inbound tmux notification arrives. Commands queued OUT of that flow —
    /// `setClientSize` (a `refresh-client -C` resize), `queueUserCommand` (a
    /// relayed pane `resize-pane`/`select-pane`), `updateColors` — would
    /// otherwise sit unsent until the next notification, which never comes on an
    /// idle session (e.g. a shell prompt with no output). The stream handler
    /// calls this right after such an enqueue to flush the resize immediately.
    ///
    /// The response FIFO stays intact: we only return the head when nothing is
    /// in flight (`command_in_flight == false`), so at most one command is sent
    /// ahead of its %begin/%end and every later command still waits in order
    /// (the `nextCommand` pump sends them as each predecessor completes). During
    /// startup we return null — the stored size is sent by `tryFinishStartup`.
    pub fn takePendingCommand(
        self: *Viewer,
        arena_alloc: Allocator,
    ) Allocator.Error!?[]const u8 {
        if (self.state != .command_queue) return null;
        if (self.command_in_flight) return null;
        const first = self.command_queue.first() orelse return null;

        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        first.formatCommand(&builder.writer) catch return error.OutOfMemory;
        self.command_in_flight = true;
        return builder.writer.buffered();
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    ///
    /// Lifetime: the returned slice and any pointers within the actions
    /// are valid only until the next call to `next()`.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.
        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
        };
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup => self.nextStartup(n),
            .command_queue => self.nextCommand(n),
        };
    }

    fn nextStartup(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            .exit => return self.defunct(),

            // The initial %begin/%end block is the response to the
            // attach command. Any end (even error) counts.
            .block_end, .block_err => {
                self.startup_got_block = true;
                return self.tryFinishStartup();
            },

            // %session-changed gives us the session ID. tmux currently
            // sends this after the block, but we handle either order.
            .session_changed => |info| {
                self.session_id = info.id;
                {
                    var win_arena = self.windows_arena.promote(self.alloc);
                    defer self.windows_arena = win_arena.state;
                    self.session_name = win_arena.allocator().dupe(u8, info.name) catch "";
                }
                self.startup_got_session = true;
                return self.tryFinishStartup();
            },

            // Startup is a special case of looking for very specific
            // things that are unlikely to expand.
            else => return &.{},
        }
    }

    /// Check if both startup prerequisites are met and transition to
    /// command_queue if so.
    fn tryFinishStartup(self: *Viewer) []const Action {
        if (!self.startup_got_block or !self.startup_got_session) return &.{};

        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        _ = arena.reset(.free_all);

        return self.enterCommandQueue(
            arena.allocator(),
            &.{ .{ .client_size = .{
                .cols = self.client_cols,
                .rows = self.client_rows,
                .enable_pause = true,
            } }, .tmux_version, .list_windows },
        ) catch {
            log.warn("failed to queue command, becoming defunct", .{});
            return self.defunct();
        };
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        // We have to be in a command queue, but the command queue MAY
        // be empty. If it is empty, then receivedCommandOutput will
        // handle it by ignoring any command output. That's okay!
        assert(self.state == .command_queue);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        // Setup our empty actions list that commands can populate.
        var actions: std.ArrayList(Action) = .empty;

        // Track whether the in-flight command slot is available. Starts true
        // if no command is currently awaiting a response. Set to true when a
        // command completes (block_end/block_err) or the queue is reset
        // (session_changed).
        var command_consumed = !self.command_in_flight;

        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),

            inline .block_end,
            .block_err,
            => |content, tag| {
                if (self.command_in_flight) {
                    self.receivedCommandOutput(
                        &actions,
                        content,
                        tag == .block_err,
                    ) catch {
                        log.warn("failed to process command output, becoming defunct", .{});
                        return self.defunct();
                    };
                    self.command_in_flight = false;
                } else {
                    log.info("unexpected block output (no command in flight) err={}", .{tag == .block_err});
                }

                // Slot is available regardless — an unexpected block
                // still means tmux finished whatever it was doing and
                // we can send the next queued command.
                command_consumed = true;
            },

            .output => |out| self.handlePaneOutput(out.pane_id, out.data),

            // Extended output: sent instead of %output when pause-after
            // flow control is enabled. Treated identically to %output;
            // the age_ms field is informational for flow control timing.
            .extended_output => |out| self.handlePaneOutput(out.pane_id, out.data),

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            // This completely replaces the viewer, so treat it like a fresh start.
            .session_changed => |info| {
                self.sessionChanged(
                    &actions,
                    info.id,
                    info.name,
                ) catch {
                    log.warn("failed to handle session change, becoming defunct", .{});
                    return self.defunct();
                };

                // Command is consumed because sessionChanged resets
                // our entire viewer.
                command_consumed = true;
            },

            // Layout changed of a single window.
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
            ) catch {
                // Note: in the future, we can probably handle a failure
                // here with a fallback to remove this one window, list
                // windows again, and try again.
                log.warn("failed to handle layout change, becoming defunct", .{});
                return self.defunct();
            },

            // A window was added to this session.
            .window_add => |_| self.refreshWindowList() catch {
                log.warn("failed to handle window add, becoming defunct", .{});
                return self.defunct();
            },

            // The active window changed in the session. Refresh the
            // window list so that layout reconciliation can update
            // the active window/pane focus. Only react if this
            // notification is for our current session.
            .session_window_changed => |info| {
                if (info.session_id == self.session_id) {
                    self.refreshWindowList() catch {
                        log.warn("failed to handle session window change, becoming defunct", .{});
                        return self.defunct();
                    };
                }
            },

            // A window was closed in this session.
            .window_close => |_| self.refreshWindowList() catch {
                log.warn("failed to handle window close, becoming defunct", .{});
                return self.defunct();
            },

            // The active pane changed in tmux. Forward to the caller
            // so it can update focus to the correct window and pane.
            .window_pane_changed => |info| {
                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                actions.append(arena.allocator(), .{
                    .focus = .{
                        .window_id = info.window_id,
                        .pane_id = info.pane_id,
                    },
                }) catch {
                    log.warn("failed to queue focus action for window={} pane={}", .{
                        info.window_id,
                        info.pane_id,
                    });
                };
            },

            // We ignore this one. It means a session was created or
            // destroyed. If it was our own session we will get an exit
            // notification very soon. If it is another session we don't
            // care.
            .sessions_changed => {},

            // Update the window name and notify the caller so it can
            // update the tab title.
            .window_renamed => |info| {
                var win_arena = self.windows_arena.promote(self.alloc);
                defer self.windows_arena = win_arena.state;
                const win_alloc = win_arena.allocator();

                for (self.windows.items) |*window| {
                    if (window.id == info.id) {
                        // Dupe the new name onto the windows arena. The old
                        // name leaks on the arena until the next full reset
                        // (receivedListWindows). This is bounded in practice:
                        // renames are infrequent, and any topology change
                        // (add/close/switch) triggers list_windows which
                        // resets the arena via free_all.
                        window.name = win_alloc.dupe(u8, info.name) catch {
                            log.warn("failed to dupe window name for rename", .{});
                            break;
                        };
                        // Emit through the shared precedence helper: the
                        // active-pane title (#T) keeps priority over the
                        // window name (#W) when one is set.
                        self.emitWindowTitle(&actions, info.id);
                        return actions.items;
                    }
                }
            },

            // A pane's mode changed (e.g., entered/exited copy mode).
            // Query the actual mode since the notification only provides
            // the pane ID, not the mode name.
            .pane_mode_changed => |info| {
                if (self.panes.contains(info.pane_id)) {
                    self.queueCommands(&.{
                        .{ .pane_mode_query = info.pane_id },
                    }) catch {
                        log.warn("failed to queue pane mode query for pane={}", .{info.pane_id});
                    };
                }
            },

            // Update the session name and notify the caller so it can
            // update the Ghostty window title. The old name leaks on
            // windows_arena until the next receivedListWindows reset
            // (see window_renamed for the same bounded-leak rationale).
            .session_renamed => |info| {
                var win_arena = self.windows_arena.promote(self.alloc);
                defer self.windows_arena = win_arena.state;
                const win_alloc = win_arena.allocator();

                self.session_name = win_alloc.dupe(u8, info.name) catch {
                    log.warn("failed to dupe session name for rename", .{});
                    return actions.items;
                };
                var act_arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = act_arena.state;
                actions.append(act_arena.allocator(), .{ .session_title = .{
                    .name = self.session_name,
                } }) catch {
                    log.warn("failed to queue session_title action", .{});
                    return actions.items;
                };
                return actions.items;
            },

            // A subscribed format value changed (`refresh-client -B`). We
            // subscribe to `@*:#{pane_title}`, so each notification carries a
            // window id and that window's active-pane title (#T). Store it and
            // refresh the tab title (pane title preferred, window name as the
            // fallback). Unsolicited like the other %-notifications, so fall
            // through and leave the command-slot bookkeeping untouched.
            .subscription_changed => |info| {
                if (std.mem.eql(u8, info.name, control.title_subscription_name)) {
                    self.setPaneTitle(info.window_id, info.value) catch {
                        log.warn("failed to store pane title for window={}", .{info.window_id});
                    };
                    self.emitWindowTitle(&actions, info.window_id);
                }
            },

            // Pause/continue relate to refresh-client -A pause-after
            // functionality. When tmux pauses a pane, it stops sending
            // %output for it (output is buffered server-side). The viewer
            // tracks the state, emits an action for runtime UI feedback,
            // and immediately queues a continue command to resume output.
            .pause => |info| {
                if (self.panes.getEntry(info.pane_id)) |entry| {
                    entry.value_ptr.*.paused = true;
                    var act_arena = self.action_arena.promote(self.alloc);
                    defer self.action_arena = act_arena.state;
                    actions.append(act_arena.allocator(), .{ .pane_paused = .{
                        .pane_id = info.pane_id,
                        .paused = true,
                    } }) catch {
                        log.warn("failed to queue pane_paused action for pane={}", .{info.pane_id});
                    };
                    // Auto-continue: immediately queue a continue command so
                    // tmux flushes buffered output and resumes the pane.
                    self.queueCommands(&.{.{ .continue_pane = info.pane_id }}) catch {
                        log.warn("failed to queue continue_pane for pane={}", .{info.pane_id});
                    };
                }
            },
            .@"continue" => |info| {
                if (self.panes.getEntry(info.pane_id)) |entry| {
                    entry.value_ptr.*.paused = false;
                    var act_arena = self.action_arena.promote(self.alloc);
                    defer self.action_arena = act_arena.state;
                    actions.append(act_arena.allocator(), .{ .pane_paused = .{
                        .pane_id = info.pane_id,
                        .paused = false,
                    } }) catch {
                        log.warn("failed to queue pane_paused action for pane={}", .{info.pane_id});
                    };
                }
            },

            // A message from the tmux server. Forward as an action so
            // the runtime can surface it (status bar, toast, etc.).
            .message => |info| {
                var act_arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = act_arena.state;
                const act_alloc = act_arena.allocator();

                const text = act_alloc.dupe(u8, info.text) catch {
                    log.warn("failed to dupe message text", .{});
                    return actions.items;
                };
                actions.append(act_alloc, .{ .message = .{
                    .text = text,
                } }) catch {
                    log.warn("failed to queue message action", .{});
                    return actions.items;
                };
                return actions.items;
            },

            // This is for other clients, which we don't do anything about.
            // For us, we'll get `exit` or `session_changed`, respectively.
            .client_detached,
            .client_session_changed,
            => {},
        }

        // After processing commands, we add our next command to
        // execute if we have one. We do this last because command
        // processing may itself queue more commands. We only emit a
        // command if a prior command was consumed (or never existed).
        if (self.state == .command_queue and command_consumed) {
            if (self.command_queue.first()) |next_command| {
                // We should not have any commands, because our nextCommand
                // always queues them.
                if (comptime std.debug.runtime_safety) {
                    for (actions.items) |action| {
                        if (action == .command) assert(false);
                    }
                }

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const arena_alloc = arena.allocator();

                var builder: std.Io.Writer.Allocating = .init(arena_alloc);
                next_command.formatCommand(&builder.writer) catch
                    return self.defunct();
                actions.append(
                    arena_alloc,
                    .{ .command = builder.writer.buffered() },
                ) catch return self.defunct();
                self.command_in_flight = true;
            }
        }

        return actions.items;
    }

    /// When the layout changes for a single window, a pane may be added
    /// or removed that we've never seen, in addition to the layout itself
    /// physically changing.
    ///
    /// To handle this, its similar to list-windows except we expect the
    /// window to already exist. We update the layout, do the initLayout
    /// call for any diffs, setup commands to capture any new panes,
    /// prune any removed panes.
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
    ) !void {
        // Find the window this layout change is for.
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };

        // Validate the layout string before doing any destructive arena
        // work. The arena reset below invalidates all existing layout
        // pointers, so a parse failure after that point would leave
        // dangling references. Validating first keeps state intact on
        // bad input from tmux.
        {
            var check_arena: ArenaAllocator = .init(self.alloc);
            defer check_arena.deinit();
            _ = Layout.parseWithChecksum(check_arena.allocator(), layout_str) catch {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ window_id, layout_str },
                );
                return;
            };
        }

        // Clone unchanged windows' layouts into a temporary arena BEFORE
        // resetting the shared arena. After arena.reset(.retain_capacity),
        // the backing pages are reused and old layout pointers become
        // invalid — new allocations from the same arena will overwrite
        // the old data. We must preserve the unchanged layouts in
        // separate memory first.
        var tmp_arena: ArenaAllocator = .init(self.alloc);
        defer tmp_arena.deinit();
        const tmp_alloc = tmp_arena.allocator();

        for (self.windows.items) |*w| {
            if (w.id == window_id) continue;
            w.layout = try w.layout.clone(tmp_alloc);
        }

        // Reset the shared windows arena and rebuild all layouts. We must
        // rebuild all windows because their layout data shares the arena.
        // Window count is small so this is cheap.
        var win_arena = self.windows_arena.promote(self.alloc);
        defer self.windows_arena = win_arena.state;

        // Save session_name to the stack before resetting, since it
        // lives on this arena and the reset invalidates the pointer.
        var saved_name_buf: [256]u8 = undefined;
        const saved_name_len = @min(self.session_name.len, saved_name_buf.len);
        @memcpy(saved_name_buf[0..saved_name_len], self.session_name[0..saved_name_len]);

        _ = win_arena.reset(.retain_capacity);
        const win_alloc = win_arena.allocator();

        // Re-dupe session_name from the stack copy onto the fresh arena.
        self.session_name = win_alloc.dupe(u8, saved_name_buf[0..saved_name_len]) catch "";

        // Parse the layout. Validation above confirmed the string is
        // well-formed, so only allocation failure is possible here.
        const new_layout: Layout = try Layout.parseWithChecksum(win_alloc, layout_str);
        window.layout = new_layout;

        // Re-clone unchanged windows' layouts from the temporary arena
        // onto the fresh shared arena. The tmp_arena data is still valid
        // since we haven't freed it yet (deferred above).
        for (self.windows.items) |*w| {
            if (w.id == window_id) continue;
            w.layout = try w.layout.clone(win_alloc);
        }

        // Reset our action arena so we can build up actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Our initial action is to definitely let the caller know that
        // some windows changed.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Sync up our panes
        try self.syncLayouts(self.windows.items);
    }

    /// Refresh the full window list from tmux. Used by window add, close,
    /// and session-window-changed notifications — all of which discard the
    /// individual window ID and do a full list-windows query instead.
    ///
    /// Coalesces duplicate requests: if a `.list_windows` command is already
    /// queued (or in-flight as the first entry), no additional one is appended.
    /// Back-to-back add/close/switch notifications during session restructuring
    /// would otherwise grow the queue with redundant full refreshes.
    fn refreshWindowList(self: *Viewer) !void {
        // Check whether list_windows is already queued.
        var it = self.command_queue.iterator(.forward);
        while (it.next()) |cmd| {
            if (cmd.* == .list_windows) return;
        }
        try self.queueCommands(&.{.list_windows});
    }

    /// Store the active-pane title for a window (from the `#{pane_title}`
    /// subscription). Owns a copy on `self.alloc`, freeing any prior value.
    /// No-op when the value is unchanged.
    fn setPaneTitle(self: *Viewer, window_id: usize, value: []const u8) Allocator.Error!void {
        if (self.pane_titles.get(window_id)) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
        }
        const dup = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(dup);
        const gop = try self.pane_titles.getOrPut(self.alloc, window_id);
        if (gop.found_existing) self.alloc.free(gop.value_ptr.*);
        gop.value_ptr.* = dup;
    }

    /// Resolve a window's tab title applying the title precedence: the
    /// active-pane title (`#T`, from the `pane_titles` cache) wins; the tmux
    /// window name (`#W`) is the fallback. Shared by `emitWindowTitle` (the
    /// live `%subscription-changed` / `%window-renamed` path) and the topology
    /// snapshot (`apprt/surface_tmux.zig`) so a full `planTmuxReconcile` rebuild
    /// preserves `#T` for inactive windows that tmux won't re-send (it dedups
    /// subscription values server-side). Returns "" when neither is known.
    /// ROOTSHELL-TMUX (id=viewer-resolve-window-title).
    pub fn resolveWindowTitle(self: *const Viewer, window_id: usize, window_name: []const u8) []const u8 {
        const pane_title: []const u8 = if (self.pane_titles.get(window_id)) |t| t else "";
        return if (pane_title.len > 0) pane_title else window_name;
    }

    /// Append a `.title` action for a window, applying the title precedence via
    /// `resolveWindowTitle`: the active-pane title (`#T`) wins; the tmux window
    /// name (`#W`) is the fallback when the pane has no title set. Mirrors a
    /// regular `tmux attach` with `set-titles-string '#T'`. No-op if neither is
    /// known yet. The title slice (pane title on `self.alloc`, or window name on
    /// the windows arena) stays valid through the synchronous action processing
    /// in the caller.
    fn emitWindowTitle(self: *Viewer, actions: *std.ArrayList(Action), window_id: usize) void {
        const window_name: []const u8 = name: {
            for (self.windows.items) |w| {
                if (w.id == window_id) break :name w.name;
            }
            break :name "";
        };
        const title: []const u8 = self.resolveWindowTitle(window_id, window_name);
        if (title.len == 0) return;

        var act_arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = act_arena.state;
        actions.append(act_arena.allocator(), .{ .title = .{
            .window_id = window_id,
            .name = title,
        } }) catch {
            log.warn("failed to queue title action for window={}", .{window_id});
        };
    }

    /// Handle output (or extended output) for a pane. Suppresses data for
    /// panes that haven't completed their capture-pane initialization
    /// sequence — processing output before capture completes would corrupt
    /// the terminal state being built up by receivedPaneHistory/Visible.
    fn handlePaneOutput(self: *Viewer, pane_id: usize, data: []const u8) void {
        const pane = if (self.panes.getEntry(pane_id)) |entry|
            entry.value_ptr.*
        else
            null;
        if (pane != null and !pane.?.initialized) {
            log.debug("suppressing output for uninitialized pane id={}", .{pane_id});
        } else {
            self.receivedOutput(pane_id, data) catch |err| {
                log.warn("failed to process output for pane id={}: {}", .{ pane_id, err });
            };
        }
    }

    /// Free retired panes whose child surface has detached (its `threadExit`
    /// cleared `renderer_mutex`). Safe to call any time; still-attached panes
    /// stay retired until their child goes away (or the viewer deinits).
    fn reapRetiredPanes(self: *Viewer) void {
        var i: usize = 0;
        while (i < self.retired_panes.items.len) {
            const pane = self.retired_panes.items[i];
            if (pane.renderer_mutex == null and !pane.pending_attach) {
                pane.deinit(self.alloc);
                self.alloc.destroy(pane);
                _ = self.retired_panes.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        // Reap any panes pruned earlier whose child surfaces have since
        // detached, before we churn the pane map again.
        self.reapRetiredPanes();

        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.*.deinit(self.alloc);
                    self.alloc.destroy(kv.value_ptr.*);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| try initLayout(
            self.alloc,
            self.colors,
            &self.panes,
            &panes,
            window.layout,
        );

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Ensure we can add the windows
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);

        // Get our list of added panes and setup our command queue
        // to populate them.
        //
        // If queueCommands fails partway through (OOM), some capture-pane
        // commands may already be queued for panes that won't be added
        // (because the panes errdefer above cleans up the new pane map).
        // This is safe: receivedPaneHistory and receivedPaneVisible both
        // check panes.getEntry() and gracefully skip untracked pane IDs.
        // CircBuf has no deleteNewest operation, and snapshotting head/full
        // is unsafe across potential resize+rotate, so we rely on the
        // response handlers' existing resilience rather than rolling back.
        {
            var panes_it = panes.iterator();
            var added: bool = false;
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) continue;
                added = true;
                try self.queueCommands(&.{
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                });

                // Hand tmux this pane's fg/bg up front so it can answer the
                // app's OSC 10/11 color queries instead of returning nothing
                // (which hangs apps like opencode that probe the background on
                // startup; see the `pane_color_report` command docs). Only sent
                // when we have concrete colors: the gateway terminal always does
                // (its defaults come from config), while tests/plain init use
                // `.default` (unset) colors and correctly skip the report.
                // Foreground (10) and background (11) go as two separate
                // commands: tmux parses only one OSC sequence per report.
                if (self.colors.foreground.get()) |fg| {
                    try self.queueCommands(&.{.{ .pane_color_report = .{
                        .pane_id = pane_id,
                        .code = 10,
                        .color = fg,
                    } }});
                }
                if (self.colors.background.get()) |bg| {
                    try self.queueCommands(&.{.{ .pane_color_report = .{
                        .pane_id = pane_id,
                        .code = 11,
                        .color = bg,
                    } }});
                }

                // Other terminal queries an app makes inside the pane (kitty
                // keyboard `\x1b[?u`, DECRQM of modes tmux ignores like 2026,
                // OSC 4 palette, OSC 12 cursor) hang for a `-CC` client because
                // tmux answers none of them. We answer those from the pane
                // terminal itself: tmux relays the app's raw query bytes in
                // `%output`, so the pane stream sees them and its `write_pty`
                // router (installed in `initLayout`) turns the reply into a
                // `send-keys` back to the app (see `flushPaneResponses` /
                // `reportColorQuery`). Queries tmux DOES answer (DA, DSR,
                // OSC 10/11, XTVERSION) are dropped by `tmuxAnswersResponse` so
                // the app never gets a double reply.
                //
                // Still unanswered (deliberate gaps; rare on startup, higher
                // cost, untested against the target app): OSC 52 clipboard reads
                // and XTGETTCAP (`\x1bP+q…`). If a capture shows an app stalling
                // on one of these, add its reply generation in
                // `stream_terminal.zig` the same way as `reportColorQuery`.
            }

            // If we added any panes, then we also want to resync the pane
            // state (terminal modes and cursor positions and so on). The
            // session id targets list-panes at the whole session so EVERY
            // window's panes are covered (ROOTSHELL-TMUX).
            if (added) try self.queueCommands(&.{.{ .pane_state = self.session_id }});
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list if it changed. We assume it didn't
        // change if our pointer is pointing to the same data.
        if (windows.ptr != self.windows.items.ptr) {
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }

        // Replace our panes
        {
            // First remove our old panes. If a pane still has a child
            // surface's renderer attached, we must not free its terminal now
            // (the child's renderer thread reads it). Retire it for deferred
            // free once the child detaches; otherwise free it immediately.
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                const pane = entry_const.value;
                if (pane.renderer_mutex != null or pane.pending_attach) {
                    // Child still attached, or one is en route: defer the free.
                    // On allocation failure we leak rather than free under a live
                    // (or imminent) renderer.
                    self.retired_panes.append(self.alloc, pane) catch {};
                } else {
                    pane.deinit(self.alloc);
                    self.alloc.destroy(pane);
                }
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
        session_name: []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        // Carry forward the current client size.
        var replacement: Viewer = try .init(self.alloc, self.client_cols, self.client_rows);
        errdefer replacement.deinit();
        // Carry the themed pane colors forward across the session reset.
        replacement.colors = self.colors;

        // Our actions must start out empty so we don't mix arenas
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Setup our command queue and put ourselves in the command queue
        // state.
        try replacement.queueCommands(&.{.list_windows});
        replacement.state = .command_queue;

        // Transfer preserved version to replacement
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;

        // Set our session ID and name, jump directly to the list
        self.session_id = session_id;
        {
            var win_arena = self.windows_arena.promote(self.alloc);
            defer self.windows_arena = win_arena.state;
            self.session_name = win_arena.allocator().dupe(u8, session_name) catch "";
        }

        assert(self.state == .command_queue);
    }

    fn receivedCommandOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        content: []const u8,
        is_err: bool,
    ) !void {
        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const command: Command = if (self.command_queue.first()) |ptr| switch (ptr.*) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        } else {
            // If we have no pending commands, this is unexpected.
            log.info("unexpected block output err={}", .{is_err});
            return;
        };
        self.command_queue.deleteOldest(1);
        defer command.deinit(self.alloc);

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Process our command
        switch (command) {
            .user, .client_size, .continue_pane, .pane_color_report, .subscribe_titles => {},

            .pane_state => {
                try self.receivedPaneState(content);

                // The pane_state command is the last in the capture
                // sequence. Mark all panes as initialized so they
                // can start receiving live output notifications.
                var panes_it = self.panes.iterator();
                while (panes_it.next()) |kv| {
                    kv.value_ptr.*.initialized = true;
                }
            },

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),

            .pane_history => |cap| try self.receivedPaneHistory(
                cap.screen_key,
                cap.id,
                content,
            ),

            .pane_visible => |cap| try self.receivedPaneVisible(
                cap.screen_key,
                cap.id,
                content,
            ),

            .tmux_version => try self.receivedTmuxVersion(content),

            .pane_mode_query => |pane_id| try self.receivedPaneMode(
                arena_alloc,
                actions,
                pane_id,
                content,
            ),
        }
    }

    fn receivedTmuxVersion(
        self: *Viewer,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return;

        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch {
            log.info("failed to parse tmux version: {s}", .{line});
            return;
        };

        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.tmux_version = try self.alloc.dupe(u8, data.version);
    }

    fn receivedPaneMode(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        pane_id: usize,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");

        // Parse the response — a single pane_mode field.
        const data = output.parseFormatStruct(
            Format.pane_mode.Struct(),
            line,
            Format.pane_mode.delim,
        ) catch {
            log.info("failed to parse pane mode response: {s}", .{line});
            return;
        };

        const entry = self.panes.getEntry(pane_id) orelse {
            log.info("pane mode response for unknown pane={}", .{pane_id});
            return;
        };

        const mode = PaneMode.fromString(data.pane_mode);
        entry.value_ptr.*.mode = mode;

        try actions.append(arena_alloc, .{ .pane_mode_changed = .{
            .pane_id = pane_id,
            .mode = mode,
        } });
    }

    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        // If there is an error, reset our actions to what it was before.
        errdefer actions.shrinkRetainingCapacity(actions.items.len);

        // Reset the shared windows arena so all layout allocations start
        // fresh. This is safe because every Window's layout data lives on
        // this arena and we are about to rebuild all of them.
        //
        // Save session_name to the stack first since it also lives on
        // this arena and the reset frees the underlying pages.
        var saved_name_buf: [256]u8 = undefined;
        const saved_name_len = @min(self.session_name.len, saved_name_buf.len);
        @memcpy(saved_name_buf[0..saved_name_len], self.session_name[0..saved_name_len]);

        var win_arena = self.windows_arena.promote(self.alloc);
        errdefer self.windows_arena = win_arena.state;
        _ = win_arena.reset(.free_all);
        const win_alloc = win_arena.allocator();

        // Re-dupe session_name from the stack copy onto the fresh arena.
        self.session_name = win_alloc.dupe(u8, saved_name_buf[0..saved_name_len]) catch "";

        // This stores our new window state from this list-windows output.
        var windows: std.ArrayList(Window) = .empty;
        defer windows.deinit(self.alloc);

        // Track the active window's ID and its active pane for initial focus.
        var active_window_id: ?usize = null;
        var active_pane_id: ?usize = null;

        // Parse all our windows
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch {
                log.info("failed to parse list-windows line: {s}", .{line});
                continue;
            };

            // Parse the layout onto the shared windows arena
            const layout: Layout = Layout.parseWithChecksum(
                win_alloc,
                data.window_layout,
            ) catch {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ data.window_id, data.window_layout },
                );
                continue;
            };

            // Record the active window and its current pane
            if (data.window_active) {
                active_window_id = data.window_id;
                active_pane_id = data.pane_id;
            }

            try windows.append(self.alloc, .{
                .id = data.window_id,
                .width = data.window_width,
                .height = data.window_height,
                .layout = layout,
                .name = try win_alloc.dupe(u8, data.window_name),
            });
        }

        // Save arena state before we hand off to syncLayouts/actions
        self.windows_arena = win_arena.state;

        // Sync up our layouts first — this copies windows into
        // self.windows so the action can reference the persistent
        // field. Using the local windows.items would be a
        // use-after-free since defer windows.deinit frees it.
        try self.syncLayouts(windows.items);

        // Subscribe (once) to each window's active-pane title now that the
        // initial capture/pane_state commands are queued. Appended last so it
        // trails — rather than interrupts — the startup command flow. The tmux
        // subscription then drives live tab-title updates via
        // %subscription-changed. See title_subscription_name.
        if (!self.title_subscription_queued) {
            try self.queueCommands(&.{.subscribe_titles});
            self.title_subscription_queued = true;
        }

        // Setup our windows action so the caller can process GUI
        // window changes. Uses self.windows.items (persistent) to
        // match the layoutChanged pattern.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Emit a focus action for the active window/pane so the caller
        // can set initial focus (or re-focus after a window change).
        // In list-windows context, pane_id is the active pane of each
        // window, so the combination of window_active + pane_id gives
        // us the session's currently focused window and pane.
        if (active_window_id) |win_id| {
            if (active_pane_id) |pane_id| {
                try actions.append(arena_alloc, .{
                    .focus = .{
                        .window_id = win_id,
                        .pane_id = pane_id,
                    },
                });
            }
        }
    }

    fn receivedPaneState(
        self: *Viewer,
        content: []const u8,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStruct(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch {
                log.info("failed to parse list-panes line: {s}", .{line});
                continue;
            };

            // Get the pane for this ID
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };
            const pane: *Pane = entry.value_ptr.*;

            if (pane.renderer_mutex) |m| m.lock();
            defer if (pane.renderer_mutex) |m| m.unlock();

            const t: *Terminal = &pane.terminal;

            // Determine which screen to use based on alternate_on
            const screen_key: ScreenSet.Key = if (data.alternate_on) .alternate else .primary;

            // Switch the terminal to the correct active screen. The
            // capture sequence processes primary then alternate, so the
            // terminal may be left on the wrong screen without this.
            _ = try t.switchScreen(screen_key);

            // Set cursor position on the appropriate screen (tmux uses 0-based)
            if (t.screens.get(screen_key)) |screen| {
                cursor: {
                    const cursor_x = std.math.cast(
                        size.CellCountInt,
                        data.cursor_x,
                    ) orelse break :cursor;
                    const cursor_y = std.math.cast(
                        size.CellCountInt,
                        data.cursor_y,
                    ) orelse break :cursor;
                    if (cursor_x >= screen.pages.cols or
                        cursor_y >= screen.pages.rows) break :cursor;
                    screen.cursorAbsolute(cursor_x, cursor_y);
                }

                // Set cursor shape on this screen
                if (data.cursor_shape.len > 0) {
                    if (std.mem.eql(u8, data.cursor_shape, "block")) {
                        screen.cursor.cursor_style = .block;
                    } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
                        screen.cursor.cursor_style = .underline;
                    } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
                        screen.cursor.cursor_style = .bar;
                    }
                }
                // "default" or unknown: leave as-is
            }

            // Set saved cursor position on the inactive screen.
            //
            // tmux's alternate_saved_x/y represents the cursor that was
            // saved when switching screen modes (mode 1049). When alternate_on
            // is true, this is the primary screen's cursor that was saved on
            // entry to alternate mode. When alternate_on is false, this would
            // apply to the alternate screen (though tmux typically sends
            // MAX_INT when there's no saved position).
            {
                const saved_screen_key: ScreenSet.Key = if (data.alternate_on) .primary else .alternate;
                if (t.screens.get(saved_screen_key)) |saved_screen| cursor: {
                    const alt_x = std.math.cast(
                        size.CellCountInt,
                        data.alternate_saved_x,
                    ) orelse break :cursor;
                    const alt_y = std.math.cast(
                        size.CellCountInt,
                        data.alternate_saved_y,
                    ) orelse break :cursor;

                    // If our coordinates are outside our screen we ignore it.
                    // tmux actually sends MAX_INT for when there isn't a set
                    // cursor position, so this isn't theoretical.
                    if (alt_x >= saved_screen.pages.cols or
                        alt_y >= saved_screen.pages.rows) break :cursor;

                    saved_screen.cursorAbsolute(alt_x, alt_y);
                }
            }

            // Set cursor visibility
            t.modes.set(.cursor_visible, data.cursor_flag);

            // Set cursor blinking
            t.modes.set(.cursor_blinking, data.cursor_blinking);

            // Terminal modes
            t.modes.set(.insert, data.insert_flag);
            t.modes.set(.wraparound, data.wrap_flag);
            t.modes.set(.keypad_keys, data.keypad_flag);
            t.modes.set(.cursor_keys, data.keypad_cursor_flag);
            t.modes.set(.origin, data.origin_flag);

            // Mouse modes
            t.modes.set(.mouse_event_any, data.mouse_all_flag);
            t.modes.set(.mouse_event_button, data.mouse_any_flag);
            t.modes.set(.mouse_event_normal, data.mouse_button_flag);
            t.modes.set(.mouse_event_x10, data.mouse_standard_flag);
            t.modes.set(.mouse_format_utf8, data.mouse_utf8_flag);
            t.modes.set(.mouse_format_sgr, data.mouse_sgr_flag);

            // Focus and bracketed paste
            t.modes.set(.focus_event, data.focus_flag);
            t.modes.set(.bracketed_paste, data.bracketed_paste);

            // Scroll region (tmux uses 0-based values)
            scroll: {
                const scroll_top = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_upper,
                ) orelse break :scroll;
                const scroll_bottom = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_lower,
                ) orelse break :scroll;
                t.scrolling_region.top = scroll_top;
                t.scrolling_region.bottom = scroll_bottom;
            }

            // Tab stops - parse comma-separated list and set
            t.tabstops.reset(0); // Clear all tabstops first
            if (data.pane_tabs.len > 0) {
                var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
                while (tabs_it.next()) |tab_str| {
                    const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
                    const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
                    if (col_cell >= t.cols) continue;
                    t.tabstops.set(col_cell);
                }
            }

            wakePane(pane);
        }
    }

    fn receivedPaneHistory(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        if (pane.renderer_mutex) |m| m.lock();
        defer if (pane.renderer_mutex) |m| m.unlock();

        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);
        const screen: *Screen = t.screens.active;

        // Get a VT stream from the terminal so we can send data as-is into
        // it. This will populate the active area too so it won't be exactly
        // correct but we'll get the active contents soon.
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);
        stream.nextSlice("\x1b[0m");

        // Populate the active area to be empty since this is only history.
        // We'll fill it with blanks and move the cursor to the top-left.
        t.carriageReturn();
        for (0..t.rows) |_| try t.index();
        t.setCursorPos(1, 1);

        // Our active area should be empty
        if (comptime std.debug.runtime_safety) {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }

        wakePane(pane);
    }

    fn receivedPaneVisible(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        if (pane.renderer_mutex) |m| m.lock();
        defer if (pane.renderer_mutex) |m| m.unlock();

        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);

        // Erase the active area and reset the cursor to the top-left
        // before writing the visible content.
        t.eraseDisplay(.complete, false);
        t.setCursorPos(1, 1);

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[0m");
        stream.nextSlice(content);
        stream.nextSlice("\x1b[0m");

        wakePane(pane);
    }

    /// Returns true if `c` is an octal digit (0-7).
    fn isOctalDigit(c: u8) bool {
        return c >= '0' and c <= '7';
    }

    /// Wake the child surface's renderer (if one is attached) so it redraws
    /// the pane after the viewer has written to its terminal. No-op when no
    /// child is attached (`wake_fn == null`). See `Pane.wake_fn`.
    fn wakePane(pane: *const Pane) void {
        if (pane.wake_fn) |f| f(pane.wake_ctx);
    }

    fn receivedOutput(
        self: *Viewer,
        id: usize,
        data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        // Lock the renderer mutex if a child surface has registered one.
        // This coordinates with the child's renderer thread which reads
        // from the same terminal under this mutex.
        if (pane.renderer_mutex) |m| m.lock();
        defer if (pane.renderer_mutex) |m| m.unlock();

        // tmux escapes control bytes (< 0x20) and the backslash itself as
        // `\ooo` (a backslash followed by exactly three octal digits) in
        // %output and %extended-output. We must unescape before feeding the
        // VT stream, otherwise sequences such as ESC (`\033`) render as literal
        // text. A `\ooo` escape never spans a single notification, so no
        // cross-call state is needed, and the decoded length never exceeds the
        // input length.
        //
        // NOTE: the upstream octal-decode PRs (#11217, #12076) were not merged
        // (code-quality review), so this is a fork-local fix on the one path
        // that actually writes pane output to a terminal.
        const buf = try self.alloc.alloc(u8, data.len);
        defer self.alloc.free(buf);
        var n: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            if (data[i] == '\\' and
                i + 3 < data.len and
                isOctalDigit(data[i + 1]) and
                isOctalDigit(data[i + 2]) and
                isOctalDigit(data[i + 3]))
            {
                // Octal `\ooo` -> byte. Computed in u16 to avoid intermediate
                // overflow; tmux only ever escapes single bytes (<= 0o377).
                const value: u16 = (@as(u16, data[i + 1] - '0') << 6) |
                    (@as(u16, data[i + 2] - '0') << 3) |
                    @as(u16, data[i + 3] - '0');
                buf[n] = @truncate(value);
                n += 1;
                i += 4;
            } else {
                buf[n] = data[i];
                n += 1;
                i += 1;
            }
        }
        pane.stream.nextSlice(buf[0..n]);

        // Route any query replies the pane terminal generated (kitty-keyboard,
        // DECRQM, OSC 4/12, ...) back to the app via send-keys. tmux relays the
        // app's raw queries in %output, so the pane terminal sees and answers
        // them here for the subset tmux itself leaves unanswered.
        self.flushPaneResponses(id, pane) catch |err| {
            log.warn("failed to flush pane {} query replies err={}", .{ id, err });
        };

        wakePane(pane);
    }

    /// `write_pty` effect installed on each pane's live stream: buffer one
    /// query reply per call for later routing (see `flushPaneResponses`).
    /// Recovers the owning `Pane` from the handler's terminal pointer, which
    /// always points at `pane.terminal` (set by `vtStream`).
    fn paneWritePty(handler: *TerminalStreamHandler, data: [:0]const u8) void {
        const pane: *Pane = @fieldParentPtr("terminal", handler.terminal);
        const alloc = handler.terminal.gpa();
        const copy = alloc.dupe(u8, data) catch return;
        pane.responses.append(alloc, copy) catch alloc.free(copy);
    }

    /// Drain the pane's buffered query replies, drop the ones tmux answers
    /// itself (to avoid a double reply corrupting the app's input), and route
    /// the rest back to the app as a `send-keys -H -t %<id>` command.
    fn flushPaneResponses(self: *Viewer, pane_id: usize, pane: *Pane) !void {
        if (pane.responses.items.len == 0) return;
        defer {
            for (pane.responses.items) |chunk| self.alloc.free(chunk);
            pane.responses.clearRetainingCapacity();
        }

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.alloc);
        for (pane.responses.items) |chunk| {
            if (tmuxAnswersResponse(chunk)) continue;
            try payload.appendSlice(self.alloc, chunk);
        }
        if (payload.items.len == 0) return;

        const cmd = try formatSendKeys(self.alloc, pane_id, payload.items);
        self.queueCommands(&.{.{ .user = cmd }}) catch |err| {
            self.alloc.free(cmd);
            return err;
        };
    }

    /// Format `send-keys -H -t %<id> XX XX ...\n` (space-separated uppercase
    /// hex) for `data`. Caller owns the returned slice. Matches the encoding in
    /// `termio/Tmux.zig` so relayed bytes reach the pane app's stdin intact.
    fn formatSendKeys(alloc: Allocator, pane_id: usize, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "send-keys -H -t %");
        var idbuf: [20]u8 = undefined;
        const ids = std.fmt.bufPrint(&idbuf, "{d}", .{pane_id}) catch unreachable;
        try out.appendSlice(alloc, ids);
        const hex = "0123456789ABCDEF";
        for (data) |b| {
            try out.append(alloc, ' ');
            try out.append(alloc, hex[b >> 4]);
            try out.append(alloc, hex[b & 0x0F]);
        }
        try out.append(alloc, '\n');
        return try out.toOwnedSlice(alloc);
    }

    /// Whether tmux itself answers the query that produced reply `resp`, so we
    /// must NOT also send it (a double reply corrupts the app's input). tmux
    /// answers DA (suppressed upstream via a null effect), DSR, XTVERSION, the
    /// color-scheme DSR, and DECRQM for modes 12/1004/1006/2004. Everything else
    /// (kitty-keyboard `…u`, DECRQM of other modes, OSC 4/12, XTGETTCAP) is for
    /// us to deliver.
    fn tmuxAnswersResponse(resp: []const u8) bool {
        // XTVERSION: DCS > | ... ST
        if (std.mem.startsWith(u8, resp, "\x1bP>|")) return true;
        // DSR operating status: CSI 0 n
        if (std.mem.eql(u8, resp, "\x1b[0n")) return true;
        if (std.mem.startsWith(u8, resp, "\x1b[")) {
            const last = resp[resp.len - 1];
            // DSR cursor position report: CSI <row> ; <col> R
            if (last == 'R') return true;
            // DECRQM report: CSI ? <mode> ; <val> $ y. tmux answers a fixed set.
            if (last == 'y' and resp.len >= 4 and resp[2] == '?') {
                var i: usize = 3;
                var mode: usize = 0;
                while (i < resp.len and resp[i] >= '0' and resp[i] <= '9') : (i += 1) {
                    mode = mode * 10 + (resp[i] - '0');
                }
                return switch (mode) {
                    12, 1004, 1006, 2004 => true,
                    else => false,
                };
            }
        }
        return false;
    }

    fn initLayout(
        gpa_alloc: Allocator,
        colors: Terminal.Colors,
        panes_old: *const PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        gpa_alloc,
                        colors,
                        panes_old,
                        panes_new,
                        l,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                // Validate dimensions before inserting into the map to
                // avoid leaving an uninitialized entry on overflow.
                const cols: size.CellCountInt = std.math.cast(size.CellCountInt, layout.width) orelse {
                    log.info("pane {} width {} overflows CellCountInt, skipping", .{ id, layout.width });
                    break :pane;
                };
                const rows: size.CellCountInt = std.math.cast(size.CellCountInt, layout.height) orelse {
                    log.info("pane {} height {} overflows CellCountInt, skipping", .{ id, layout.height });
                    break :pane;
                };

                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                // If we already have this pane, it is already initialized
                // so just copy it over (and resize if the layout changed).
                if (panes_old.getEntry(id)) |entry| {
                    gop.value_ptr.* = entry.value_ptr.*;
                    const pane = gop.value_ptr.*;

                    // Resize the terminal if the pane's grid dimensions
                    // changed (e.g. after a split or window resize). This
                    // keeps the viewer's terminal in sync with tmux's
                    // actual pane size. Terminal.resize no-ops when the
                    // dimensions already match.
                    //
                    // Hold the child surface's renderer mutex (if a child is
                    // attached) across the resize: it mutates the terminal's
                    // PageList while the child's renderer thread reads the same
                    // terminal under that mutex. Without this lock a relayout
                    // during heavy output (e.g. running btop in a pane) races
                    // the renderer and crashes in updateFrame/updateExtraRows.
                    if (pane.renderer_mutex) |m| m.lock();
                    defer if (pane.renderer_mutex) |m| m.unlock();
                    try pane.terminal.resize(
                        gpa_alloc,
                        cols,
                        rows,
                    );
                    break :pane;
                }

                var t: Terminal = try .init(gpa_alloc, .{
                    .cols = cols,
                    .rows = rows,
                    // tmux replays each pane's full history via `capture-pane -S -`
                    // (up to tmux's history-limit, default 2000 lines). The Terminal
                    // default max_scrollback is only 10_000 bytes (~a few lines), which
                    // would discard almost all of it, so give panes a real scrollback
                    // budget matching ghostty's default scrollback-limit (10 MiB).
                    // Actual memory tracks content and is bounded by tmux's own
                    // history-limit, so this is a ceiling, not a reservation.
                    .max_scrollback = 10 * 1024 * 1024,
                    // Use the gateway terminal's themed colors so default-background
                    // cells match the app theme rather than the built-in dark default
                    // (`.default` colors leave background `.unset`).
                    .colors = colors,
                });
                errdefer t.deinit(gpa_alloc);

                const pane = try gpa_alloc.create(Pane);
                errdefer gpa_alloc.destroy(pane);
                pane.* = .{
                    .terminal = t,
                    .stream = undefined,
                    // A child surface will be created for this new pane (the
                    // reconcile emits an ensure_pane op). Mark it en route so no
                    // free path reclaims it before that child attaches.
                    .pending_attach = true,
                };
                pane.stream = pane.terminal.vtStream();
                // Install the query-reply router so this pane answers the
                // terminal queries tmux does NOT handle for a control client
                // (kitty-keyboard, DECRQM of unknown modes, OSC 4/12, etc.).
                // Replies are buffered here and routed back to the app via
                // `send-keys` after each `%output` feed; queries tmux DOES
                // answer are dropped in `flushPaneResponses` to avoid double
                // replies. (vtStream defaults to readonly, so capture replays
                // and other vtStream users are unaffected.)
                pane.stream.handler.effects.write_pty = &paneWritePty;
                gop.value_ptr.* = pane;
            },
        }
    }

    /// Enters the command queue state from any other state, queueing
    /// the commands and returning an action to execute the first command.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state != .command_queue);
        assert(commands.len > 0);

        // Build our command string to send for the action.
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        commands[0].formatCommand(&builder.writer) catch return error.OutOfMemory;
        const action: Action = .{ .command = builder.writer.buffered() };

        // Add our commands
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        for (commands) |cmd| self.command_queue.appendAssumeCapacity(cmd);

        // Move into the command queue state
        self.state = .command_queue;
        self.command_in_flight = true;

        return self.singleAction(action);
    }

    /// Queue multiple commands to execute. This doesn't add anything
    /// to the actions queue or return actions or anything because the
    /// command_queue state will automatically send the next command when
    /// it receives output.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
        }
    }

    /// Queue a raw, pre-formatted tmux command (already including its trailing
    /// newline) that was issued out-of-band by a child pane backend —
    /// `resize-pane`, `select-pane`, `select-window`. Routing it through the
    /// command queue (rather than writing it straight to tmux) is essential:
    /// the queue serializes it AFTER any in-flight capture-pane sequence and
    /// consumes its (empty) %begin/%end response, so it can never inject a
    /// stray block that shifts the response FIFO — which otherwise mis-matches
    /// pane_visible/pane_state and strands a pane on the wrong (scrollback-less)
    /// screen on attach. The bytes are copied; the copy is freed in
    /// `Command.deinit` via the `.user` arm.
    pub fn queueUserCommand(self: *Viewer, cmd: []const u8) Allocator.Error!void {
        const copy = try self.alloc.dupe(u8, cmd);
        errdefer self.alloc.free(copy);
        try self.queueCommands(&.{.{ .user = copy }});
    }

    /// Queue a command relayed out-of-band from a child pane backend
    /// (`termio.Tmux`): `resize-pane` (the pane's grid changed — keyboard,
    /// font, rotation), `select-pane`, `select-window`. Most are forwarded
    /// verbatim like `queueUserCommand`, with ONE translation:
    ///
    /// A `resize-pane` targeting a pane that is the ONLY pane in its window is
    /// rewritten to a `client_size` (`refresh-client -C`). In a single-pane
    /// window the pane fills the window, whose size equals the control client
    /// size, so tmux treats `resize-pane` as a no-op — the window only reflows
    /// when the client size changes. The pane's grid (computed by the child
    /// surface, already cell-, font-, and inset-aware exactly like a normal
    /// surface) IS the desired window/client size, so we forward it as such.
    /// This keeps the whole resize path in the core/Zig layer — the apprt only
    /// drives `ghostty_surface_set_size`, identical to a non-tmux surface.
    ///
    /// Multi-pane `resize-pane` (a split-divider drag) is forwarded unchanged.
    pub fn queueRelayedPaneCommand(self: *Viewer, cmd: []const u8) Allocator.Error!void {
        if (parseResizePane(cmd)) |rp| {
            if (self.windowIsSinglePane(rp.pane_id)) {
                // Reuse setClientSize: it stores the dims and queues a tracked
                // client_size ONLY in the command_queue state (during startup it
                // just stores, so the size is sent by tryFinishStartup and never
                // injected mid-startup-sequence).
                self.setClientSize(rp.cols, rp.rows);
                return;
            }
        }
        try self.queueUserCommand(cmd);
    }

    const ResizePane = struct {
        pane_id: usize,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    };

    /// Parse `resize-pane -t %<id> -x <cols> -y <rows>` — the exact format
    /// emitted by `termio.Tmux.resize`. Returns null for any other command.
    /// Byte-level, no allocation.
    fn parseResizePane(cmd: []const u8) ?ResizePane {
        const trimmed = std.mem.trim(u8, cmd, " \r\n");
        if (!std.mem.startsWith(u8, trimmed, "resize-pane ")) return null;
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        _ = it.next() orelse return null; // resize-pane
        var pane_id: ?usize = null;
        var cols: ?size.CellCountInt = null;
        var rows: ?size.CellCountInt = null;
        while (it.next()) |tok| {
            const val = it.next() orelse break;
            if (std.mem.eql(u8, tok, "-t")) {
                if (val.len < 2 or val[0] != '%') return null;
                pane_id = std.fmt.parseInt(usize, val[1..], 10) catch return null;
            } else if (std.mem.eql(u8, tok, "-x")) {
                cols = std.fmt.parseInt(size.CellCountInt, val, 10) catch return null;
            } else if (std.mem.eql(u8, tok, "-y")) {
                rows = std.fmt.parseInt(size.CellCountInt, val, 10) catch return null;
            }
        }
        return .{
            .pane_id = pane_id orelse return null,
            .cols = cols orelse return null,
            .rows = rows orelse return null,
        };
    }

    /// Whether `pane_id` is the sole pane in its window (its window's layout
    /// root is a single leaf). Returns false when the pane's window is unknown
    /// — be conservative and forward the `resize-pane` rather than resizing the
    /// whole client.
    fn windowIsSinglePane(self: *const Viewer, pane_id: usize) bool {
        for (self.windows.items) |w| {
            if (layoutContainsPane(w.layout, pane_id)) {
                return w.layout.content == .pane;
            }
        }
        return false;
    }

    fn layoutContainsPane(layout: Layout, pane_id: usize) bool {
        return switch (layout.content) {
            .pane => |id| id == pane_id,
            .horizontal, .vertical => |children| {
                for (children) |child| {
                    if (layoutContainsPane(child, pane_id)) return true;
                }
                return false;
            },
        };
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    fn defunct(self: *Viewer) []const Action {
        self.state = .defunct;
        return self.singleAction(.exit);
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We need two things before we can
    /// proceed: (1) the initial %begin/%end block for the attach
    /// command, and (2) a %session-changed notification for the
    /// session ID. tmux currently sends the block first, but we
    /// handle either order for robustness.
    startup,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: if self.command_queue.len > 0, then the first
    /// command in the queue has already been sent to tmux (via a
    /// `command` Action). The next output is assumed to be the result
    /// of this command.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send a command Action for the first command in the queue.
    command_queue,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture history for the given pane ID.
    pane_history: CapturePane,

    /// Capture visible area for the given pane ID.
    pane_visible: CapturePane,

    /// Capture the pane terminal state as best we can. The pane ID(s)
    /// are part of the output so we can map it back to our panes. The
    /// payload is the session id: pane_state is targeted via
    /// `list-panes -s -t $<id>` so the state for EVERY window's panes is
    /// returned, not just the current window's. Without session scope,
    /// panes in non-active windows never get switched back to their real
    /// screen and stay stranded blank on the alternate screen.
    /// ROOTSHELL-TMUX
    pane_state: usize,

    /// Get the tmux server version.
    tmux_version,

    /// Subscribe to each window's active-pane title via `refresh-client -B`.
    /// tmux then emits `%subscription-changed` whenever a window's
    /// `#{pane_title}` (`#T`) changes, which the viewer maps onto the tab
    /// title. The subscription is client-scoped and persists across session
    /// changes, so it is issued once during startup. See
    /// `title_subscription_name`.
    subscribe_titles,

    /// Query the current mode of a specific pane via display-message.
    /// Used to determine whether a pane is in copy-mode, view-mode, etc.
    pane_mode_query: usize,

    /// Set the control client size. tmux uses this (along with other
    /// attached clients) to determine window dimensions. When
    /// `enable_pause` is set, the pause-after flow control flag is
    /// also sent in the same refresh-client command.
    client_size: struct {
        cols: size.CellCountInt,
        rows: size.CellCountInt,
        enable_pause: bool = false,
    },

    /// Resume a paused pane. Sent as `refresh-client -A '%<id>:continue'`.
    continue_pane: usize,

    /// Report one of this pane's colors to tmux via
    /// `refresh-client -r "%<id>:<OSC report>"`. tmux stores it in
    /// `wp->control_fg`/`wp->control_bg` and uses it to answer an app's
    /// `OSC 10`/`OSC 11` color queries (`window_pane_get_fg_control_client` /
    /// `window_pane_get_bg_control_client`). Without this, tmux has no client
    /// color, `input_osc_colour_reply` returns nothing for the query, and the
    /// app (e.g. opencode) blocks forever waiting for a background-color reply.
    /// This mirrors iTerm2's per-pane `refresh-client -r` color reporting.
    ///
    /// Foreground (`code = 10`) and background (`code = 11`) MUST be sent as two
    /// SEPARATE commands: tmux's `cmd_refresh_report` calls `tty_keys_colours`
    /// once and it parses exactly one OSC sequence, so a combined buffer would
    /// only register the first color (iTerm2 sends two reports for the same
    /// reason).
    pane_color_report: struct {
        pane_id: usize,
        /// OSC code: 10 (foreground) or 11 (background).
        code: u8,
        color: color.RGB,
    },

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: []const u8,

    const CapturePane = struct {
        id: usize,
        screen_key: ScreenSet.Key,
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_visible,
            .pane_state,
            .tmux_version,
            .subscribe_titles,
            .pane_mode_query,
            .client_size,
            .continue_pane,
            .pane_color_report,
            => {},
            .user => |v| alloc.free(v),
        };
    }

    /// Format the command into the command that should be executed
    /// by tmux. Trailing newlines are appended so this can be sent as-is
    /// to tmux.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            .pane_history => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -S - = start at the top of history ("-")
                // -E -1 = end at the last line of history (1 before the
                //   visible area is -1).
                // -t %{d} = target a specific pane ID
                "capture-pane -p -e -q {s}-S - -E -1 -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_visible => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -t %{d} = target a specific pane ID
                // (no -S/-E = capture visible area only)
                "capture-pane -p -e -q {s}-t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            // ROOTSHELL-TMUX: `-s -t $<session>` lists panes for the WHOLE
            // session (every window), not just the current window. Without
            // `-s`, tmux returns only the current window's panes, so panes in
            // other windows never receive their pane_state and stay stranded
            // on the blank alternate screen (no scrollback). Mirrors iTerm2's
            // `list-panes -s -t $<sessionId>` (TmuxController.m).
            .pane_state => |session_id| try writer.print(
                "list-panes -s -t ${d} -F '{s}'\n",
                .{ session_id, comptime Format.list_panes.comptimeFormat() },
            ),

            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'\n",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),

            // Subscribe to every window's active-pane title. `@*` = all
            // windows; the format is evaluated in each window's context, so
            // `#{pane_title}` resolves to that window's active pane's title.
            // Single-quoted so tmux stores `#{pane_title}` as the literal
            // format (expanded per tick), not at parse time.
            .subscribe_titles => try writer.writeAll(
                "refresh-client -B '" ++ control.title_subscription_name ++ ":@*:#{pane_title}'\n",
            ),

            .pane_mode_query => |pane_id| try writer.print(
                "display-message -p -t %{d} '{s}'\n",
                .{ pane_id, comptime Format.pane_mode.comptimeFormat() },
            ),

            .client_size => |cs| {
                try writer.print("refresh-client -C {d}x{d}", .{ cs.cols, cs.rows });
                if (cs.enable_pause) {
                    try writer.print(" -f pause-after={d}", .{PAUSE_AFTER_BYTES});
                }
                try writer.writeAll("\n");
            },

            .continue_pane => |pane_id| try writer.print(
                "refresh-client -A '%{d}:continue'\n",
                .{pane_id},
            ),

            .pane_color_report => |r| {
                // Hand tmux one color (OSC 10 fg or OSC 11 bg) so it can answer
                // the pane app's color query. The control bytes are written as
                // the ASCII-escaped octal `\033` (NOT a raw 0x1B) and the ST's
                // trailing backslash as `\\`: tmux's command lexer
                // (`yylex_token_escape`) unescapes `\033`->ESC and `\\`->`\`
                // inside the double-quoted argument, then `cmd_refresh_report`
                // feeds the resulting raw OSC reply to `tty_keys_colours`.
                // Because the bytes on the wire carry no 0x1B, the app-side
                // gateway report stripper (which drops any raw escape on the
                // command channel) leaves this command intact. The doubled-hex
                // (`{x:0>2}` twice per channel) matches tmux's own
                // `input_osc_colour_reply` 16-bit `rgb:RRRR/GGGG/BBBB` format.
                try writer.print(
                    "refresh-client -r \"%{d}:" ++
                        "\\033]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\\033\\\\\"\n",
                    .{
                        r.pane_id,
                        r.code,
                        r.color.r, r.color.r,
                        r.color.g, r.color.g,
                        r.color.b, r.color.b,
                    },
                );
            },

            .user => |v| try writer.writeAll(v),
        }
    }
};

/// Format strings used for commands in our viewer.
const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. This must be a character
    /// guaranteed to not appear in any of the variable outputs.
    delim: u8,

    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            // Cursor position & appearance
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_blinking,
            // Alternate screen
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            // Terminal modes
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            // Mouse modes
            //
            // tmux variable names differ from xterm mode names:
            //   mouse_all_flag    -> mouse_event_any    (report all motion)
            //   mouse_any_flag    -> mouse_event_button (report button-motion)
            //   mouse_button_flag -> mouse_event_normal (report button press/release)
            //   mouse_standard_flag -> mouse_event_x10  (legacy X10 compat)
            .mouse_all_flag,
            .mouse_any_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            // Focus & special features
            .focus_flag,
            .bracketed_paste,
            // Scroll region
            .scroll_region_upper,
            .scroll_region_lower,
            // Tab stops
            .pane_tabs,
        },
    };

    const list_windows: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .window_id,
            .window_active,
            .pane_id,
            .window_width,
            .window_height,
            .window_layout,
            .window_name,
        },
    };

    const tmux_version: Format = .{
        .delim = ' ',
        .vars = &.{.version},
    };

    const pane_mode: Format = .{
        .delim = ' ',
        .vars = &.{.pane_mode},
    };

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);

        // Common mistake, forgetting the newline on a command.
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};

test "client_size command formats refresh-client" {
    const cmd: Command = .{ .client_size = .{ .cols = 120, .rows = 36 } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings("refresh-client -C 120x36\n", result);
}

test "client_size with enable_pause formats pause-after flag" {
    const cmd: Command = .{ .client_size = .{ .cols = 80, .rows = 24, .enable_pause = true } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings("refresh-client -C 80x24 -f pause-after=200\n", result);
}

test "continue_pane command formats refresh-client -A" {
    const cmd: Command = .{ .continue_pane = 42 };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings("refresh-client -A '%42:continue'\n", result);
}

test "subscribe_titles command formats refresh-client -B" {
    const cmd: Command = .subscribe_titles;
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings(
        "refresh-client -B 'ghostty_title:@*:#{pane_title}'\n",
        result,
    );
}

test "pane_state formats session-scoped list-panes" {
    // ROOTSHELL-TMUX: pane_state MUST be `-s -t $<session>` so tmux returns
    // panes for EVERY window in the session, not just the current window.
    // Without session scope, panes in non-active windows never get switched
    // back to their real screen on attach and stay stranded blank on the
    // alternate screen (the multi-window scrollback-restore bug).
    const cmd: Command = .{ .pane_state = 3 };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expect(std.mem.startsWith(u8, result, "list-panes -s -t $3 -F '"));
    try testing.expect(std.mem.endsWith(u8, result, "'\n"));
}

test "pane_color_report formats refresh-client -r with escaped OSC 11 (bg)" {
    const cmd: Command = .{ .pane_color_report = .{
        .pane_id = 2,
        .code = 11,
        .color = .{ .r = 0x00, .g = 0x10, .b = 0x20 },
    } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    // On the wire the control bytes are the literal ASCII octal escape `\033`
    // and the ST's trailing backslash is doubled (`\\`); tmux's command lexer
    // unescapes both inside the double-quoted argument before handing the raw
    // OSC reply to `cmd_refresh_report`/`tty_keys_colours`.
    try testing.expectEqualStrings(
        "refresh-client -r \"%2:\\033]11;rgb:0000/1010/2020\\033\\\\\"\n",
        result,
    );
}

test "pane_color_report formats OSC 10 (fg)" {
    const cmd: Command = .{ .pane_color_report = .{
        .pane_id = 5,
        .code = 10,
        .color = .{ .r = 0xc0, .g = 0xc1, .b = 0xc2 },
    } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings(
        "refresh-client -r \"%5:\\033]10;rgb:c0c0/c1c1/c2c2\\033\\\\\"\n",
        result,
    );
}

test "tmuxAnswersResponse drops tmux-handled replies, forwards the rest" {
    // Dropped: tmux answers these itself, so a second reply would corrupt input.
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[4;1R")); // DSR cursor position
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[0n")); // DSR operating status
    try testing.expect(Viewer.tmuxAnswersResponse("\x1bP>|tmux 3.6\x1b\\")); // XTVERSION
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[?2004;1$y")); // DECRQM bracketed paste
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[?12;1$y")); // DECRQM cursor blink

    // Forwarded: tmux ignores these for a -CC client, so we must deliver them.
    try testing.expect(!Viewer.tmuxAnswersResponse("\x1b[?2026;2$y")); // DECRQM synchronized output
    try testing.expect(!Viewer.tmuxAnswersResponse("\x1b[?0u")); // kitty keyboard
    try testing.expect(!Viewer.tmuxAnswersResponse("\x1b]4;1;rgb:0000/0000/0000\x1b\\")); // OSC 4
    try testing.expect(!Viewer.tmuxAnswersResponse("\x1b]12;rgb:ffff/ffff/ffff\x07")); // OSC 12
}

test "formatSendKeys hex-encodes bytes targeting the pane" {
    const cmd = try Viewer.formatSendKeys(testing.allocator, 5, "\x1b[?0u");
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("send-keys -H -t %5 1B 5B 3F 30 75\n", cmd);
}

test "pane DCS terminates and doesn't swallow the rest of the stream" {
    // Regression: opencode (and other apps that detect $TMUX) emit
    // `ESC P tmux; ...` passthrough DCS in %output. The fork's parse table keeps
    // the parser in dcs_passthrough on ESC/C1 (so the gateway control-mode DCS
    // isn't cut short), so without the pane handler's own ST detection the DCS
    // would eat the following `1049h` and the entire UI -> blank pane.
    const dcs_prefixes = [_][]const u8{
        "\x1bPt\x1b\\", // minimal DCS, 7-bit ST
        "\x1bPtmux;\x1b\\", // tmux passthrough, empty
        "\x1bPtmux;\x1b\x1b[?1016$p\x1b\\", // tmux passthrough with doubled escapes
        "\x1bPq\x1b\\", // sixel-style
        "\x1bP+q544E\x1b\\", // XTGETTCAP
        "\x1bPt\x9c", // 8-bit C1 ST
    };
    for (dcs_prefixes) |prefix| {
        var t: Terminal = try .init(testing.allocator, .{ .cols = 100, .rows = 30 });
        defer t.deinit(testing.allocator);
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(prefix);
        // A mode-set and a print after the DCS must take effect.
        stream.nextSlice("\x1b[?1049h");
        try testing.expectEqual(.alternate, t.screens.active_key);
        stream.nextSlice("ABC");
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expect(std.mem.indexOf(u8, str, "ABC") != null);
    }
}

test "pane_color_report contains no raw ESC so it survives the gateway strip" {
    // The app-side `stripTerminalReports` drops any raw 0x1B on the tmux command
    // channel. This command MUST carry only ASCII-escaped `\033` (never a raw
    // ESC) so the color report actually reaches tmux instead of being stripped.
    const cmd: Command = .{ .pane_color_report = .{
        .pane_id = 7,
        .code = 11,
        .color = .{ .r = 0x1b, .g = 0x1b, .b = 0x1b },
    } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expect(std.mem.indexOfScalar(u8, result, 0x1b) == null);
}

test "setClientSize queues command in command_queue state" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence + pane_state + subscribe_titles.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });

    // Now in command_queue state with empty queue and no command in flight.
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expect(!viewer.command_in_flight);
    try testing.expect(viewer.command_queue.empty());

    // setClientSize should queue a client_size command.
    viewer.setClientSize(132, 43);
    try testing.expectEqual(@as(size.CellCountInt, 132), viewer.client_cols);
    try testing.expectEqual(@as(size.CellCountInt, 43), viewer.client_rows);
    try testing.expect(!viewer.command_queue.empty());

    // Next notification should trigger sending the queued command.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "x" } } },
            .contains_command = "refresh-client -C 132x43",
        },
        // Response to the refresh-client command
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });

    // Queue should be empty again, no command in flight.
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(!viewer.command_in_flight);
}

test "takePendingCommand flushes an idle-queued resize and keeps FIFO order" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain the capture-pane sequence + pane_state + subscribe_titles.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });

    // Idle command_queue: nothing to flush yet.
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expect(!viewer.command_in_flight);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try testing.expect((try viewer.takePendingCommand(arena.allocator())) == null);
    }

    // A resize queues a client_size command. takePendingCommand should now
    // format + return it and mark it in flight (this is the idle-session flush
    // that the pull-based pump would otherwise miss).
    viewer.setClientSize(132, 43);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
        try testing.expectEqualStrings("refresh-client -C 132x43\n", cmd);
        try testing.expect(viewer.command_in_flight);

        // A second resize before the first response must NOT be flushed early:
        // it waits behind the in-flight command so the response FIFO stays in
        // order.
        viewer.setClientSize(100, 50);
        try testing.expect((try viewer.takePendingCommand(arena.allocator())) == null);
    }

    // The first command's response sends the second in order via the pull pump.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client -C 100x50",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(!viewer.command_in_flight);
}

test "parseResizePane parses target/cols/rows, rejects others" {
    const rp = Viewer.parseResizePane("resize-pane -t %7 -x 120 -y 40\n").?;
    try testing.expectEqual(@as(usize, 7), rp.pane_id);
    try testing.expectEqual(@as(size.CellCountInt, 120), rp.cols);
    try testing.expectEqual(@as(size.CellCountInt, 40), rp.rows);

    // Not a resize-pane.
    try testing.expect(Viewer.parseResizePane("select-pane -t %7\n") == null);
    try testing.expect(Viewer.parseResizePane("select-window -t @1\n") == null);
    // Missing a dimension.
    try testing.expect(Viewer.parseResizePane("resize-pane -t %7 -x 120\n") == null);
    // Target without the % sigil.
    try testing.expect(Viewer.parseResizePane("resize-pane -t 7 -x 1 -y 1\n") == null);
}

test "queueRelayedPaneCommand rewrites a single-pane resize to client_size" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    // Standard startup leaving a single-pane window @0 with pane %0.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expect(viewer.windowIsSinglePane(0));

    // A pane resize for the sole pane is rewritten to `refresh-client -C`.
    try viewer.queueRelayedPaneCommand("resize-pane -t %0 -x 120 -y 40\n");
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
    try testing.expectEqualStrings("refresh-client -C 120x40\n", cmd);
}

test "takePendingCommand returns null during startup" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    // In startup state setClientSize only stores dims; nothing is queued, so
    // there is nothing to flush (tryFinishStartup sends the stored size).
    try testing.expectEqual(.startup, viewer.state);
    viewer.setClientSize(100, 50);

    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try viewer.takePendingCommand(arena.allocator())) == null);
}

test "setClientSize stores dimensions but does not queue during startup" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    // Viewer is in startup state
    try testing.expectEqual(.startup, viewer.state);
    viewer.setClientSize(100, 50);
    try testing.expectEqual(@as(size.CellCountInt, 100), viewer.client_cols);
    try testing.expectEqual(@as(size.CellCountInt, 50), viewer.client_rows);

    // Queue should still be empty (no command queued during startup)
    try testing.expect(viewer.command_queue.empty());
}

test "startup sends client_size with pause-after before version query" {
    var viewer = try Viewer.init(testing.allocator, 132, 43);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            // First command should be refresh-client with dimensions and pause-after
            .contains_command = "refresh-client",
            .check_command = (struct {
                fn check(_: *Viewer, cmd: []const u8) anyerror!void {
                    try testing.expectEqualStrings(
                        "refresh-client -C 132x43 -f pause-after=200\n",
                        cmd,
                    );
                }
            }).check,
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "message notification produces message action" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 80 24 b25d,80x24,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Send a %message notification
        .{
            .input = .{ .tmux = .{ .message = .{
                .text = "Session created session 1",
            } } },
            .contains_tags = &.{.message},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .message) {
                            try testing.expectEqualStrings(
                                "Session created session 1",
                                action.message.text,
                            );
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .exit },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1 @0 1 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Now session changes - should reset everything but keep version
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                    // Version should still be preserved
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$2 @1 1 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "initial flow" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "refresh-client",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
            // pane_history for pane 0 (primary)
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // .windows must be emitted before .command so that
                    // the surface layer sees topology before outgoing
                    // commands trigger further protocol traffic.
                    var windows_idx: ?usize = null;
                    var command_idx: ?usize = null;
                    for (actions, 0..) |action, i| {
                        if (windows_idx == null and action == .windows) windows_idx = i;
                        if (command_idx == null and action == .command) command_idx = i;
                    }
                    try testing.expect(windows_idx != null);
                    try testing.expect(command_idx != null);
                    try testing.expect(windows_idx.? < command_idx.?);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\Hello, world!
                ,
            } },
            // Moves on to pane_visible for pane 0 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Completes pane_visible(1, alternate), triggers pane_state
            .contains_command = "list-panes",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // pane_state response completes initialization
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // All panes should now be marked as initialized
                    var it = v.panes.iterator();
                    while (it.next()) |kv| {
                        try testing.expect(kv.value_ptr.*.initialized);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No output action forwarded — the viewer's pane terminal
                    // is now authoritative (single-terminal architecture).
                    try testing.expectEqual(0, actions.len);
                    // Viewer processes output into its own pane terminal.
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Output for untracked pane is silently dropped.
                    // No action produced.
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "startup session before block" {
    // Verify that %session-changed arriving before %begin/%end
    // still completes startup correctly.
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Session arrives first (reversed order from normal)
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 7,
                .name = "reversed",
            } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session info should be stored
                    try testing.expectEqual(7, v.session_id);
                    // But we haven't finished startup yet (no block)
                    try testing.expect(v.state == .startup);
                    // No commands should be emitted yet
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        // Block arrives second — this should complete startup
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should now be in command_queue state
                    try testing.expect(v.state == .command_queue);
                    try testing.expectEqual(7, v.session_id);
                }
            }).check,
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout change" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate),
        // pane_state, and the trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Now send a layout_change that splits into two panes
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 1 window
                    try testing.expectEqual(1, v.windows.items.len);
                    // Should now have 2 panes (0 and 2)
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    // Commands should be queued for the new pane (4 capture-pane + 1 pane_state)
                    try testing.expectEqual(5, v.command_queue.len());
                    // Pane 0 was 83x44 before the split. After the
                    // layout change it should be resized to 83x22.
                    const pane0 = v.panes.get(0).?;
                    try testing.expectEqual(83, pane0.terminal.cols);
                    try testing.expectEqual(22, pane0.terminal.rows);
                    // Pane 2 is new — created at 83x21.
                    const pane2 = v.panes.get(2).?;
                    try testing.expectEqual(83, pane2.terminal.cols);
                    try testing.expectEqual(21, pane2.terminal.rows);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout change resizes existing pane without structural change" {
    // When a tmux window is resized (e.g. the terminal emulator is
    // resized), tmux sends a %layout-change with the same pane
    // structure but different dimensions. The viewer must resize the
    // pane's shadow terminal to match.
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Initial window: single pane at 83x44
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane0 = v.panes.get(0).?;
                    try testing.expectEqual(83, pane0.terminal.cols);
                    try testing.expectEqual(44, pane0.terminal.rows);
                }
            }).check,
        },
        // Complete capture-pane commands for pane 0, pane_state, and the
        // trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Window resized to 120x50 — same pane, different dimensions
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "acfd,120x50,0,0,0",
                .visible_layout = "acfd,120x50,0,0,0",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Still one pane, no new captures queued
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.command_queue.empty());
                    // Terminal dimensions must match the new layout
                    const pane0 = v.panes.get(0).?;
                    try testing.expectEqual(120, pane0.terminal.cols);
                    try testing.expectEqual(50, pane0.terminal.rows);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change does not return command when queue not empty" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send a layout_change that splits into two panes.
        // This should NOT return a command action since queue was not empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // Should not contain a command action
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, pane_state, and the
        // trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send a layout_change that splits into two panes.
        // This should return a command action since we're queuing commands
        // for the new pane and the queue was empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_add - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_add - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Should not contain a command action since queue was not empty
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    // But list_windows should be in the queue
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "session_window_changed queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send session_window_changed - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{ .session_id = 1, .window_id = 2 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "session_window_changed queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send session_window_changed - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{ .session_id = 1, .window_id = 2 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_close queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_close - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_close = .{ .id = 0 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_close queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_close - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .window_close = .{ .id = 0 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Should not contain a command action since queue was not empty
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    // But list_windows should be in the queue
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "refreshWindowList coalesces duplicate list_windows" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Send window_add — queues list_windows
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        // Send window_close — should NOT add another list_windows (coalesced)
        .{
            .input = .{ .tmux = .{ .window_close = .{ .id = 0 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Still exactly 1 list_windows in the queue (coalesced)
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        // Send session_window_changed — should also be coalesced
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 1,
                .window_id = 1,
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Still exactly 1 list_windows in the queue (coalesced)
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "two pane flow with pane state" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial block_end from attach
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Session changed notification
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "refresh-client",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.session_id);
                }
            }).check,
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // list-windows output with 2 panes in a vertical split
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 165 79 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4] bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqual(0, window.id);
                    try testing.expectEqual(165, window.width);
                    try testing.expectEqual(79, window.height);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        // capture-pane pane 0 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                \\prompt %
                ,
            } },
        },
        // capture-pane pane 0 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        // History has 2 lines with "prompt %" (padded to screen width)
                        try testing.expect(std.mem.containsAtLeast(u8, str, 2, "prompt %"));
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                }
            }).check,
        },
        // capture-pane pane 0 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 0 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 4 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
        },
        // capture-pane pane 4 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        // Active screen starts with "prompt %" at beginning
                        try testing.expect(std.mem.startsWith(u8, str, "prompt %"));
                    }
                }
            }).check,
        },
        // capture-pane pane 4 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 4 alternate visible (empty). Completing the
        // capture sequence emits the trailing pane_state command, which MUST
        // be session-scoped (`list-panes -s -t $<id>`) so tmux returns panes
        // for every window in the session, not just the current window —
        // otherwise non-active windows' panes never get switched back to
        // their real screen and stay stranded blank (ROOTSHELL-TMUX). The
        // `$0` confirms the session id was threaded into the command.
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-panes -s -t $0",
        },
        // list-panes output with terminal state
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;42;0;1;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                \\%4;10;5;1;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane 0: cursor at (42, 0), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(42, screen.cursor.x);
                        try testing.expectEqual(0, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                    // Pane 4: cursor at (10, 5), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr.*;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(10, screen.cursor.x);
                        try testing.expectEqual(5, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout change preserves other windows on shared arena" {
    // Validates that the shared windows_arena correctly preserves
    // layout data for unchanged windows when layoutChanged rebuilds.
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Two windows: @0 with pane 0, @1 with pane 1
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 80 24 b25d,80x24,0,0,0 bash
                \\$0 @1 0 %1 80 24 b25e,80x24,0,0,1 vim
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.windows.items.len);
                    try testing.expectEqual(0, v.windows.items[0].id);
                    try testing.expectEqual(1, v.windows.items[1].id);
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 and pane 1
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Now send a layout_change for window @0 that splits it
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 2 windows
                    try testing.expectEqual(2, v.windows.items.len);
                    // Window @0 should now have a vertical split
                    try testing.expect(v.windows.items[0].layout.content == .vertical);
                    // Window @1 should still be a single pane with id 1
                    try testing.expectEqual(1, v.windows.items[1].layout.content.pane);
                    // Pane count should now be 3 (0, 1, 2)
                    try testing.expectEqual(3, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "Action.format preserves normal formatting for command action" {
    // Regression guard: non-output actions should still format
    // their payload contents normally.
    const action: Viewer.Action = .{ .command = "list-windows\n" };

    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try action.format(&builder.writer);
    const result = builder.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, result, "command") != null);
    try testing.expect(std.mem.indexOf(u8, result, "list-windows") != null);
}

test "Action.format handles exit action" {
    const action: Viewer.Action = .exit;

    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try action.format(&builder.writer);
    const result = builder.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, result, "exit") != null);
}

test "window_pane_changed produces focus action" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with two panes
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands (4 per pane × 2 panes = 8),
        // then pane_state and the trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Send window_pane_changed - should produce .focus action
        .{
            .input = .{ .tmux = .{ .window_pane_changed = .{
                .window_id = 0,
                .pane_id = 1,
            } } },
            .contains_tags = &.{.focus},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .focus) {
                            try testing.expectEqual(@as(usize, 0), action.focus.window_id);
                            try testing.expectEqual(@as(usize, 1), action.focus.pane_id);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "Action.format handles focus action" {
    const action: Viewer.Action = .{ .focus = .{
        .window_id = 5,
        .pane_id = 12,
    } };

    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try action.format(&builder.writer);
    const result = builder.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, result, "focus") != null);
}

test "output suppressed for uninitialized panes" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive window with single pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane should exist but not be initialized
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(!pane.initialized);
                }
            }).check,
        },
        // Output arrives during capture-pane sequence — should be suppressed
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "premature output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No actions should be emitted — output is suppressed
                    try testing.expectEqual(0, actions.len);
                    // Viewer's terminal should NOT have the premature output
                    const pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.*.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expectEqualStrings("", str);
                }
            }).check,
        },
        // Complete capture-pane sequence: 4 captures + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // pane_state completes — pane should now be initialized
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(pane.initialized);
                }
            }).check,
        },
        // Output after initialization — should be processed by viewer
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "real output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No actions emitted — viewer processes output
                    // internally into the pane terminal.
                    try testing.expectEqual(0, actions.len);
                    // Viewer's terminal should have the output
                    const pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.*.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "real output"));
                }
            }).check,
        },
    });
}

test "window_renamed produces title action" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with single pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence (4 captures + pane_state)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Rename window — should produce .title action
        .{
            .input = .{ .tmux = .{ .window_renamed = .{
                .id = 0,
                .name = "vim",
            } } },
            .contains_tags = &.{.title},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .title) {
                            try testing.expectEqual(@as(usize, 0), action.title.window_id);
                            try testing.expectEqualStrings("vim", action.title.name);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                    // Window name in viewer state should also be updated
                    try testing.expectEqualStrings("vim", v.windows.items[0].name);
                }
            }).check,
        },
    });
}

test "session_renamed produces session_title action" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "original",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Rename session — should produce .session_title action
        .{
            .input = .{ .tmux = .{ .session_renamed = .{
                .name = "renamed-session",
            } } },
            .contains_tags = &.{.session_title},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .session_title) {
                            try testing.expectEqualStrings("renamed-session", action.session_title.name);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                    // Session name in viewer state should be updated
                    try testing.expectEqualStrings("renamed-session", v.session_name);
                }
            }).check,
        },
    });
}

test "list_windows stores window name" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive list-windows with a named window
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 htop
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqualStrings("htop", v.windows.items[0].name);
                }
            }).check,
        },
    });
}

test "list_windows emits focus action for active window" {
    // Verifies that receivedListWindows emits a .focus action targeting
    // the active window and its current pane from the list-windows output.
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .focus },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .focus) {
                            try testing.expectEqual(0, action.focus.window_id);
                            try testing.expectEqual(0, action.focus.pane_id);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "list_windows emits focus for active window in multi-window session" {
    // With two windows, only @0 is active. The focus action should
    // target @0 and its current pane %0, not the inactive @1.
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 80 24 b25d,80x24,0,0,0 bash
                \\$0 @1 0 %1 80 24 b25e,80x24,0,0,1 vim
                ,
            } },
            .contains_tags = &.{ .windows, .focus },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .focus) {
                            // Active window is @0 with current pane %0
                            try testing.expectEqual(0, action.focus.window_id);
                            try testing.expectEqual(0, action.focus.pane_id);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "pause notification triggers auto-continue and full pause cycle" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence (4 captures + pane_state) and the
        // trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Pause pane 0 — should set paused=true, emit pane_paused,
        // and auto-queue a continue_pane command.
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 0 } } },
            .contains_tags = &.{ .pane_paused, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Pane should be marked paused
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(pane.paused);
                    // Action should indicate paused=true
                    var found_paused = false;
                    var found_continue = false;
                    for (actions) |action| {
                        if (action == .pane_paused) {
                            try testing.expectEqual(@as(usize, 0), action.pane_paused.pane_id);
                            try testing.expect(action.pane_paused.paused);
                            found_paused = true;
                        }
                        if (action == .command) {
                            if (std.mem.startsWith(u8, action.command, "refresh-client -A")) {
                                found_continue = true;
                            }
                        }
                    }
                    try testing.expect(found_paused);
                    try testing.expect(found_continue);
                }
            }).check,
        },
        // Receive continue_pane response (no-op), then %continue
        // notification clears the paused state.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .@"continue" = .{ .pane_id = 0 } } },
            .contains_tags = &.{.pane_paused},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Pane should no longer be paused
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(!pane.paused);
                    // Action should indicate paused=false
                    var found = false;
                    for (actions) |action| {
                        if (action == .pane_paused) {
                            try testing.expectEqual(@as(usize, 0), action.pane_paused.pane_id);
                            try testing.expect(!action.pane_paused.paused);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "pause for unknown pane is ignored" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Pause for unknown pane 99 — should be silently ignored
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 99 } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No pane_paused action should be emitted
                    for (actions) |action| {
                        if (action == .pane_paused) {
                            return error.UnexpectedAction;
                        }
                    }
                }
            }).check,
        },
    });
}

test "pane_mode_changed queues query and updates state on response" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence (4 captures + pane_state) and the
        // trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Pane mode changed notification — should queue display-message query
        .{
            .input = .{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 0 } } },
            .contains_command = "display-message",
        },
        // Response with copy-mode — should update state and emit action
        .{
            .input = .{ .tmux = .{ .block_end = "copy-mode" } },
            .contains_tags = &.{.pane_mode_changed},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Pane mode should be updated to copy
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(Viewer.PaneMode.copy, pane.mode);
                    // Action should report the mode change
                    var found = false;
                    for (actions) |action| {
                        if (action == .pane_mode_changed) {
                            try testing.expectEqual(@as(usize, 0), action.pane_mode_changed.pane_id);
                            try testing.expectEqual(Viewer.PaneMode.copy, action.pane_mode_changed.mode);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "pane_mode_changed for unknown pane is ignored" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Pane mode changed for unknown pane 99 — should not queue a command
        .{
            .input = .{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 99 } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No command should be queued (no display-message)
                    for (actions) |action| {
                        if (action == .command) {
                            return error.UnexpectedCommand;
                        }
                    }
                }
            }).check,
        },
    });
}

test "pane_mode_changed empty response means normal mode" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence and the trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // First, enter copy mode so we have a non-normal state
        .{
            .input = .{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 0 } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "copy-mode" } },
            .contains_tags = &.{.pane_mode_changed},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(Viewer.PaneMode.copy, pane.mode);
                }
            }).check,
        },
        // Now exit copy mode — empty response means normal
        .{
            .input = .{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 0 } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_tags = &.{.pane_mode_changed},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Pane mode should be back to normal
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(Viewer.PaneMode.normal, pane.mode);
                    // Action should report normal mode
                    var found = false;
                    for (actions) |action| {
                        if (action == .pane_mode_changed) {
                            try testing.expectEqual(@as(usize, 0), action.pane_mode_changed.pane_id);
                            try testing.expectEqual(Viewer.PaneMode.normal, action.pane_mode_changed.mode);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "layout_change mid-capture suppresses output for uninitialized pane" {
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup: single-pane layout
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial layout with one pane (%0)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture sequence for pane 0: 4 capture-pane + 1 pane_state,
        // then the trailing title subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                    // Pane 0 should be initialized
                    const pane0 = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(pane0.initialized);
                }
            }).check,
        },
        // Layout change splits into two panes: %0 and %2.
        // This queues capture commands for the new pane %2.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // New pane %2 should NOT be initialized yet
                    const pane2 = v.panes.getEntry(2).?.value_ptr.*;
                    try testing.expect(!pane2.initialized);
                    // Existing pane %0 should still be initialized
                    const pane0 = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(pane0.initialized);
                }
            }).check,
        },
        // Output arrives for pane %2 BEFORE its capture completes.
        // It should be suppressed (no actions emitted).
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 2, .data = "premature output" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        // Output for pane %0 (already initialized) should still work.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "valid output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Viewer processes into its own terminal (no output
                    // action), but the data should be in the terminal.
                    try testing.expectEqual(0, actions.len);
                    const pane0: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane0.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "valid output"));
                }
            }).check,
        },
        // Complete the capture sequence for pane %2:
        // 4 capture-pane responses
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // pane_state response — this marks all panes as initialized
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane %2 should now be initialized
                    const pane2 = v.panes.getEntry(2).?.value_ptr.*;
                    try testing.expect(pane2.initialized);
                }
            }).check,
        },
        // Now output for pane %2 should be processed normally.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 2, .data = "post-init output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane2: *Viewer.Pane = v.panes.getEntry(2).?.value_ptr.*;
                    const screen: *Screen = pane2.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "post-init output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "pane state alternate_saved cursor applies to primary screen" {
    // When alternate_on=1, the alternate_saved_x/y values represent the
    // cursor position saved from the primary screen on entry to alternate
    // mode. They must be applied to the primary screen, not the alternate
    // screen (which would overwrite the active cursor).
    var viewer = try Viewer.init(testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup sequence
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Single pane layout
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 %0 80 24 b25d,80x24,0,0,0 bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // capture-pane pane 0 primary history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 0 primary visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 0 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 0 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // pane_state: alternate_on=1, cursor at (10,2) on alternate screen,
        // alternate_saved at (5,3) which should go to primary screen.
        //
        // Format: pane_id;cursor_x;cursor_y;cursor_flag;cursor_shape;
        //         cursor_blinking;alternate_on;alternate_saved_x;
        //         alternate_saved_y;insert_flag;wrap_flag;keypad_flag;
        //         keypad_cursor_flag;origin_flag;mouse_all_flag;
        //         mouse_any_flag;mouse_button_flag;mouse_standard_flag;
        //         mouse_utf8_flag;mouse_sgr_flag;focus_flag;
        //         bracketed_paste;scroll_region_upper;scroll_region_lower;
        //         pane_tabs
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;10;2;1;;0;1;5;3;0;1;0;0;0;0;0;0;0;0;0;0;0;0;23;8,16,24,32,40,48,56,64,72,80
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const t: *Terminal = &pane.terminal;
                    // Terminal should be on alternate screen
                    try testing.expectEqual(ScreenSet.Key.alternate, t.screens.active_key);
                    // Active (alternate) cursor should be at (10, 2)
                    const alt_screen: *Screen = t.screens.get(.alternate).?;
                    try testing.expectEqual(10, alt_screen.cursor.x);
                    try testing.expectEqual(2, alt_screen.cursor.y);
                    // Saved cursor (primary screen) should be at (5, 3)
                    const pri_screen: *Screen = t.screens.get(.primary).?;
                    try testing.expectEqual(5, pri_screen.cursor.x);
                    try testing.expectEqual(3, pri_screen.cursor.y);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
