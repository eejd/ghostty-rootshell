//! ROOTSHELL-TMUX: fork-owned sidecar extracted from apprt/surface.zig.
//!
//! Holds the plain value types carried by the fork's tmux control-mode surface
//! messages. These were lifted out of the `Message` union in the
//! upstream-shared apprt/surface.zig to shrink the tmux footprint there.
//!
//! The `Message` union keeps re-export aliases (`Message.TmuxTopologySnapshot`,
//! `Message.TmuxTitleChanged`, `Message.TmuxFocusChanged`) pointing here, so
//! external references like `apprt.surface.Message.TmuxTopologySnapshot` keep
//! resolving. The relay writer (`SurfaceRelayWriter`) intentionally stays in
//! apprt/surface.zig because it is tightly coupled to that file's `Message` /
//! `Mailbox` types (moving it would create a circular import for no real gain).
//!
//! None of these types reference `Message`/`Mailbox`, so there is no import
//! cycle here. Carry this file forward verbatim on rebase. See
//! docs/tmux-control-mode-fork.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");

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

/// A captured (pane_id -> viewer Pane pointer) entry. ROOTSHELL-TMUX
/// (id=snapshot-pane-refs): the viewer's `Pane` boxes are heap-allocated and
/// stable, but the `PanesMap` *backing* is NOT — an `AutoArrayHashMapUnmanaged`
/// reallocs/frees its arrays on growth/deinit. So the snapshot captures the
/// stable pointers on the IO thread (where the map is not being mutated)
/// instead of handing the app thread a live map to `getEntry()` into
/// off-thread, which would be a concurrent read of reallocated/freed memory.
///
/// The pointed-to `Pane` boxes' LIFETIME is held for the crossing by a per-pane
/// refcount (id=viewer-snapshot-refcount): `initFromWindows` takes a hold on
/// each captured pane (released in the snapshot's `deinit`), and
/// `planTmuxReconcile` takes a further hold on each pane its op batch references
/// (released when the reconcile payload is freed, AFTER the Swift apply). Every
/// viewer free path honors these holds (`Pane.isRetained`), so the app thread
/// can safely dereference these pointers even if the pane's child detaches and
/// the IO thread tries to remove it mid-flight.
pub const PaneRef = struct {
    id: usize,
    pane: *terminal.tmux.Viewer.Pane,
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

    /// ROOTSHELL-TMUX (id=snapshot-resolved-titles): resolved tab title per
    /// window, parallel to `windows`, owned by `arena`. Applies the same
    /// precedence as `Viewer.resolveWindowTitle` (active-pane `#T` wins, window
    /// name `#W` is the fallback) at snapshot-build time — on the IO thread,
    /// where `pane_titles` is stable — so `planTmuxReconcile` doesn't clobber
    /// inactive windows' `#T` titles with the bare window name (tmux dedups
    /// subscription values, so it won't re-send an unchanged pane title).
    titles: []const []const u8,

    /// Captured (pane_id -> *Pane) pointers, owned by `arena`. Cloned from the
    /// viewer's live panes map on the IO thread at snapshot time so the app
    /// thread never reads the live map's reallocating backing (see `PaneRef`).
    /// Empty when no viewer panes are available (e.g., in tests). Lets the
    /// reconcile planner pass viewer-owned terminal pointers to child surfaces.
    panes: []const PaneRef,

    /// Create a snapshot by deep-copying `windows`. Each window's
    /// layout tree is cloned into a dedicated arena so the snapshot
    /// is independent of the source memory.
    pub fn initFromWindows(
        alloc: Allocator,
        windows: []const terminal.tmux.Viewer.Window,
        panes: ?*const terminal.tmux.Viewer.PanesMap,
        // ROOTSHELL-TMUX (id=snapshot-pane-titles): the viewer's active-pane
        // title cache, so each window's resolved tab title preserves `#T`.
        // Null on the empty-snapshot / test paths (falls back to window name).
        pane_titles: ?*const terminal.tmux.Viewer.PaneTitlesMap,
    ) Allocator.Error!*TmuxTopologySnapshot {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const cloned_windows = try arena_alloc.alloc(
            terminal.tmux.Viewer.Window,
            windows.len,
        );
        const cloned_titles = try arena_alloc.alloc([]const u8, windows.len);
        for (windows, 0..) |window, i| {
            cloned_windows[i] = .{
                .id = window.id,
                .width = window.width,
                .height = window.height,
                .layout = try window.layout.clone(arena_alloc),
                .name = try arena_alloc.dupe(u8, window.name),
            };
            // Resolve the tab title with the same precedence as the live path
            // (active-pane `#T` wins, window name `#W` is the fallback).
            const resolved: []const u8 = if (pane_titles) |pt|
                (if (pt.get(window.id)) |t| (if (t.len > 0) t else window.name) else window.name)
            else
                window.name;
            cloned_titles[i] = try arena_alloc.dupe(u8, resolved);
        }

        // Snapshot the (pane_id -> *Pane) mapping into the arena. Read the live
        // map synchronously here on the IO thread (it is not being mutated
        // concurrently with its owning gateway), capturing only the stable boxed
        // pointers — see `PaneRef`.
        const cloned_panes: []const PaneRef = if (panes) |p| blk: {
            const refs = try arena_alloc.alloc(PaneRef, p.count());
            var it = p.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) {
                refs[i] = .{ .id = kv.key_ptr.*, .pane = kv.value_ptr.* };
            }
            break :blk refs;
        } else &.{};

        const self = try alloc.create(TmuxTopologySnapshot);
        self.* = .{
            .alloc = alloc,
            .arena = arena,
            .windows = cloned_windows,
            .titles = cloned_titles,
            .panes = cloned_panes,
        };

        // Take a snapshot hold on each captured pane now that the snapshot is
        // fully built (no fallible step follows, so no error path can leave a
        // ref acquired-but-never-released). This keeps the pane boxes alive while
        // their raw pointers ride the mailbox to the app thread and through
        // `planTmuxReconcile`. Released in `deinit`. ROOTSHELL-TMUX
        // (id=viewer-snapshot-refcount)
        for (cloned_panes) |ref| ref.pane.acquireSnapshotRef();
        return self;
    }

    /// Free all owned memory: the arena (windows + layouts) and the
    /// struct itself.
    pub fn deinit(self: *TmuxTopologySnapshot) void {
        // Drop the snapshot holds taken in initFromWindows BEFORE freeing the
        // arena that owns the PaneRef slice. ROOTSHELL-TMUX
        // (id=viewer-snapshot-refcount)
        for (self.panes) |ref| ref.pane.releaseSnapshotRef();
        const alloc = self.alloc;
        self.arena.deinit();
        alloc.destroy(self);
    }
};

test {
    std.testing.refAllDecls(@This());
}
