const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Config = @import("../config.zig").Config;
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The message types that can be sent to a single surface.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = MessageData(u8, 255);

    /// Set the title of the surface.
    /// TODO: we should change this to a "WriteReq" style structure in
    /// the termio message so that we can more efficiently send strings
    /// of any length
    set_title: [256]u8,

    /// Report the window title back to the terminal
    report_title: ReportTitleStyle,

    /// Set the mouse shape.
    set_mouse_shape: terminal.MouseShape,

    /// Read the clipboard and write to the pty.
    clipboard_read: apprt.Clipboard,

    /// Write the clipboard contents.
    clipboard_write: struct {
        clipboard_type: apprt.Clipboard,
        req: WriteReq,
    },

    /// Change the configuration to the given configuration. The pointer is
    /// not valid after receiving this message so any config must be used
    /// and derived immediately.
    change_config: *const Config,

    /// Close the surface. This will only close the current surface that
    /// receives this, not the full application.
    close: void,

    /// The child process running in the surface has exited. This may trigger
    /// a surface close, it may not. Additional details about the child
    /// command are given in the `ChildExited` struct.
    child_exited: ChildExited,

    /// Show a desktop notification.
    desktop_notification: struct {
        /// Desktop notification title.
        title: [63:0]u8,

        /// Desktop notification body.
        body: [255:0]u8,
    },

    /// Health status change for the renderer.
    renderer_health: renderer.Health,

    /// Tell the surface to present itself to the user. This may require raising
    /// a window and switching tabs.
    present_surface: void,

    /// Notifies the surface that password input has started within
    /// the terminal. This should always be followed by a false value
    /// unless the surface exits.
    password_input: bool,

    /// A terminal color was changed using OSC sequences.
    color_change: terminal.osc.color.ColoredTarget,

    /// Notifies the surface that a tick of the timer that is timing
    /// out selection scrolling has occurred. "selection scrolling"
    /// is when the user has clicked and dragged the mouse outside
    /// the viewport of the terminal and the terminal is scrolling
    /// the viewport to follow the mouse cursor.
    selection_scroll_tick: bool,

    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,

    /// Report the progress of an action using a GUI element
    progress_report: terminal.osc.Command.ProgressReport,

    /// A command has started in the shell, start a timer.
    start_command,

    /// A command has finished in the shell, stop the timer and send out
    /// notifications as appropriate. The optional u8 is the exit code
    /// of the command.
    stop_command: ?u8,

    /// The scrollbar state changed for the surface.
    scrollbar: terminal.Scrollbar,

    /// Search progress update
    search_total: ?usize,

    /// Selected search index change
    search_selected: ?usize,

    /// The tmux viewer's window topology has changed. The snapshot is a
    /// deep copy of the viewer's windows and layouts, allocated on its own
    /// arena. The receiver (app thread) owns the snapshot and must call
    /// deinit when done.
    tmux_topology_changed: *TmuxTopologySnapshot,

    /// A tmux child pane is relaying a command to its parent surface's
    /// pty. The child's IO thread constructs this message targeting the
    /// parent surface's mailbox. The parent surface's `handleMessage`
    /// forwards the command bytes to its own termio mailbox via `queueIo`.
    ///
    /// This preserves the SPSC invariant: the parent's IO thread remains
    /// the single consumer of its termio mailbox. The child never writes
    /// directly to the parent's mailbox.
    tmux_write_command: WriteReq,

    /// The active pane changed in tmux (`%window-pane-changed`
    /// notification). The parent surface's stream handler constructs
    /// this message so the app thread can update focus to the correct
    /// window tab and pane surface.
    ///
    /// Lightweight value type — no heap allocation needed since it
    /// carries only two IDs.
    tmux_focus_changed: TmuxFocusChanged,

    /// A tmux title changed — either a window rename (tab title) or
    /// a session rename (Ghostty window title). The parent surface's
    /// stream handler constructs this message so the app thread can
    /// update the displayed title.
    ///
    /// Lightweight value type — fixed-size buffer, no heap allocation.
    tmux_title_changed: TmuxTitleChanged,

    pub const ReportTitleStyle = enum {
        csi_21_t,

        // This enum is a placeholder for future title styles.
    };

    pub const ChildExited = extern struct {
        exit_code: u32,
        runtime_ms: u64,

        /// Make this a valid gobject if we're in a GTK environment.
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk,
            => @import("gobject").ext.defineBoxed(
                ChildExited,
                .{ .name = "GhosttyApprtChildExited" },
            ),

            .none => void,
        };
    };

    /// Carries the window and pane IDs from a tmux
    /// `%window-pane-changed` notification.
    pub const TmuxFocusChanged = struct {
        window_id: usize,
        pane_id: usize,
    };

    /// Carries a title change from a tmux `%window-renamed` or
    /// `%session-renamed` notification. Fixed-size buffer following
    /// the `set_title: [256]u8` pattern.
    pub const TmuxTitleChanged = struct {
        /// For tab title (window rename): the tmux window ID.
        /// For window title (session rename): null.
        tmux_window_id: ?usize,

        /// Title string. Stored inline in a fixed buffer.
        title_buf: [256]u8 = undefined,
        title_len: u8 = 0,

        pub fn init(tmux_window_id: ?usize, name: []const u8) TmuxTitleChanged {
            var result: TmuxTitleChanged = .{
                .tmux_window_id = tmux_window_id,
            };
            const len: u8 = @intCast(@min(name.len, result.title_buf.len - 1));
            @memcpy(result.title_buf[0..len], name[0..len]);
            result.title_len = len;
            return result;
        }

        pub fn title(self: *const TmuxTitleChanged) []const u8 {
            return self.title_buf[0..self.title_len];
        }
    };

    /// A deep-copy snapshot of the tmux viewer's window topology. Owns
    /// all memory through a dedicated arena so it is safe to pass across
    /// thread boundaries via the surface mailbox.
    ///
    /// Follows the `change_config: *const Config` pattern: the IO thread
    /// allocates the snapshot, sends a pointer through the mailbox, and
    /// the app thread calls `deinit` after consuming it.
    pub const TmuxTopologySnapshot = struct {
        /// Backing allocator used to allocate this struct itself.
        alloc: Allocator,

        /// Arena that owns all cloned window/layout data.
        arena: std.heap.ArenaAllocator,

        /// Deep-copied window list. Layout trees are fully independent
        /// of the viewer's backing memory.
        windows: []const terminal.tmux.Viewer.Window,

        /// Optional pointer to the viewer's panes map. The viewer's
        /// panes are heap-allocated (boxed) so the pointers remain stable
        /// across map mutations. This allows the reconcile planner to
        /// pass viewer-owned terminal pointers to child surfaces.
        /// Null when no viewer panes are available (e.g., in tests).
        panes: ?*const terminal.tmux.Viewer.PanesMap,

        /// Create a snapshot by deep-copying `windows`. Each window's
        /// layout tree is cloned into a dedicated arena so the snapshot
        /// is independent of the source memory.
        pub fn initFromWindows(
            alloc: Allocator,
            windows: []const terminal.tmux.Viewer.Window,
            panes: ?*const terminal.tmux.Viewer.PanesMap,
        ) Allocator.Error!*TmuxTopologySnapshot {
            var arena: std.heap.ArenaAllocator = .init(alloc);
            errdefer arena.deinit();
            const arena_alloc = arena.allocator();

            const cloned_windows = try arena_alloc.alloc(
                terminal.tmux.Viewer.Window,
                windows.len,
            );
            for (windows, 0..) |window, i| {
                cloned_windows[i] = .{
                    .id = window.id,
                    .width = window.width,
                    .height = window.height,
                    .layout = try window.layout.clone(arena_alloc),
                    .name = try arena_alloc.dupe(u8, window.name),
                };
            }

            const self = try alloc.create(TmuxTopologySnapshot);
            self.* = .{
                .alloc = alloc,
                .arena = arena,
                .windows = cloned_windows,
                .panes = panes,
            };
            return self;
        }

        /// Free all owned memory: the arena (windows + layouts) and the
        /// struct itself.
        pub fn deinit(self: *TmuxTopologySnapshot) void {
            const alloc = self.alloc;
            self.arena.deinit();
            alloc.destroy(self);
        }
    };
};

/// A ControlWriter implementation that routes tmux commands through
/// the app mailbox to the parent surface. When a child tmux pane runs
/// on its own IO thread, it cannot safely write directly into the
/// parent's SPSC termio mailbox.
///
/// Instead, command bytes are wrapped in an `apprt.surface.Message`
/// (.tmux_write_command) and pushed to the parent surface's mailbox.
/// The app mailbox is MPSC-safe, so any thread can push. The app
/// thread delivers the message to the parent surface's `handleMessage`,
/// which forwards the command bytes into the parent's termio mailbox
/// via `queueIo` — preserving the SPSC invariant.
///
/// ## Relay Path
///
///   Child IO thread: SurfaceRelayWriter.writeFn()
///     → constructs WriteReq from command bytes
///     → pushes .tmux_write_command to parent surface mailbox
///     → (app mailbox MPSC push, safe from any thread)
///   App thread: drainMailbox → parent Surface.handleMessage
///     → .tmux_write_command → queueIo(.write_small/.write_alloc)
///     → parent termio mailbox (SPSC: app thread is single producer)
///
/// ## Lifetime
///
/// The `parent_mailbox` must remain valid for the lifetime of this
/// writer. In practice, the parent surface outlives all child surfaces
/// it creates.
pub const SurfaceRelayWriter = struct {
    const ControlWriter = terminal.tmux.ControlWriter;

    parent_mailbox: Mailbox,
    alloc: Allocator,

    pub fn controlWriter(self: *SurfaceRelayWriter) ControlWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *anyopaque, data: []const u8) ControlWriter.WriteError!void {
        const self: *SurfaceRelayWriter = @ptrCast(@alignCast(context));

        // Construct a surface-level WriteReq from the command bytes.
        // Surface WriteReq (MessageData(u8, 255)) can hold up to 255
        // bytes inline; larger commands are heap-allocated.
        const SurfaceWriteReq = Message.WriteReq;
        const req = SurfaceWriteReq.init(self.alloc, data) catch
            return error.WriteFailed;

        // Push to the parent surface's mailbox. This goes through the
        // app mailbox (MPSC-safe). Use .forever since we don't hold
        // any mutex that could deadlock with the app thread.
        _ = self.parent_mailbox.push(
            .{ .tmux_write_command = req },
            .{ .forever = {} },
        );
    }
};

/// A surface mailbox.
pub const Mailbox = struct {
    surface: *Surface,
    app: App.Mailbox,

    /// Send a message to the surface.
    pub fn push(
        self: Mailbox,
        msg: Message,
        timeout: App.Mailbox.Queue.Timeout,
    ) App.Mailbox.Queue.Size {
        // Surface message sending is actually implemented on the app
        // thread, so we have to rewrap the message with our surface
        // pointer and send it to the app thread.
        return self.app.push(.{
            .surface_message = .{
                .surface = self.surface,
                .message = msg,
            },
        }, timeout);
    }
};

/// Context for new surface creation to determine inheritance behavior
pub const NewSurfaceContext = enum(c_int) {
    window = 0,
    tab = 1,
    split = 2,
};

pub fn shouldInheritWorkingDirectory(context: NewSurfaceContext, config: *const Config) bool {
    return switch (context) {
        .window => config.@"window-inherit-working-directory",
        .tab => config.@"tab-inherit-working-directory",
        .split => config.@"split-inherit-working-directory",
    };
}

/// Returns a new config for a surface for the given app that should be
/// used for any new surfaces. The resulting config should be deinitialized
/// after the surface is initialized.
pub fn newConfig(
    app: *const App,
    config: *const Config,
    context: NewSurfaceContext,
) Allocator.Error!Config {
    // Create a shallow clone
    var copy = config.shallowClone(app.alloc);

    // Our allocator is our config's arena
    const alloc = copy._arena.?.allocator();

    // Get our previously focused surface for some inherited values.
    const prev = app.focusedSurface();
    if (prev) |p| {
        if (shouldInheritWorkingDirectory(context, config)) {
            if (try p.pwd(alloc)) |pwd| {
                copy.@"working-directory" = .{ .path = pwd };
            }
        }
    }

    return copy;
}
