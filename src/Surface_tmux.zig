//! ROOTSHELL-TMUX: fork-owned sidecar extracted from Surface.zig.
//!
//! Holds the tmux control-mode reconcile vocabulary (`TmuxReconcileOp`,
//! `TmuxReconcilePayload`) and the pure planner functions that turn a tmux
//! topology snapshot into an ordered op list which the apprt applies to its
//! own native tab/split/surface primitives.
//!
//! None of this touches `Surface` state — the planners are pure over snapshot
//! data — which is exactly why it lives here instead of inline in the
//! upstream-shared Surface.zig. Surface.zig re-exports `TmuxReconcileOp` and
//! `TmuxReconcilePayload` (the C ABI path `CoreSurface.TmuxReconcile{Op,Payload}`
//! used by apprt/embedded.zig and apprt/action.zig must keep resolving) and
//! calls the planners via `@import("Surface_tmux.zig")`.
//!
//! Carry this whole file forward verbatim on rebase. See
//! docs/tmux-control-mode-fork.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const terminal = @import("terminal/main.zig");
// The snapshot sidecar only imports `terminal` (no Message/Mailbox), so this
// pulls in no apprt import cycle. ROOTSHELL-TMUX (id=snapshot-pane-refs)
const surface_tmux = @import("apprt/surface_tmux.zig");
const PaneRef = surface_tmux.PaneRef;

/// The reconcile planner (in `Surface.handleMessage(.tmux_topology_changed)`)
/// converts a `TmuxTopologySnapshot` into an ordered list of these ops.
/// The apprt receives them via the `tmux_reconcile` action and applies
/// them using its own tab/split/surface primitives.
pub const TmuxReconcileOp = union(enum) {
    /// Begin an atomic reconcile transaction. The apprt may defer
    /// visual updates until `sync_windows_end`.
    sync_windows_begin,

    /// Ensure a tab exists for the given tmux window ID. If it
    /// already exists, retain it; otherwise create a new tab.
    ensure_window: struct {
        tmux_window_id: usize,
        width: usize,
        height: usize,
        /// tmux window index (display order). The app sorts its tmux tabs by
        /// this. ROOTSHELL-TMUX (id=tmux-window-order)
        index: usize = 0,
    },

    /// Ensure a pane leaf surface exists for the given pane ID
    /// within the specified tmux window. The surface should use
    /// the tmux backend with the given pane ID.
    ensure_pane: struct {
        tmux_window_id: usize,
        pane_id: usize,
        /// Pointer to the viewer-owned terminal for this pane. The child
        /// surface's renderer will read from this terminal, implementing
        /// the single-terminal architecture where the viewer's pane
        /// terminals ARE the terminals. Null when the viewer terminal is
        /// not yet available (e.g., during tests without a real viewer).
        viewer_terminal: ?*terminal.Terminal = null,
        /// Pointer to the viewer-owned pane. The child surface registers
        /// its renderer mutex to this pane during threadEnter, enabling
        /// the viewer to coordinate terminal writes with the renderer.
        viewer_pane: ?*terminal.tmux.Viewer.Pane = null,
    },

    /// Update the split tree of the given tmux window to match
    /// the provided layout shape. The layout is borrowed from
    /// the payload's arena and valid for the duration of the action.
    set_layout: struct {
        tmux_window_id: usize,
        layout: *const terminal.tmux.Layout,
        /// The pane id shown fullscreen when the window is zoomed, or 0 when the
        /// window is not zoomed. ROOTSHELL-TMUX (id=tmux-zoom)
        zoomed_pane_id: usize = 0,
    },

    /// Move focus to the specified tmux window and pane.
    set_focus: struct {
        tmux_window_id: usize,
        pane_id: usize,
    },

    /// Remove any tabs/panes whose tmux window/pane IDs are not
    /// in the provided sets. `window_ids` and `pane_ids` are
    /// sorted slices for binary search.
    prune_absent: struct {
        window_ids: []const usize,
        pane_ids: []const usize,
    },

    /// End the atomic reconcile transaction. The apprt should
    /// commit any deferred visual updates and restore stable focus.
    sync_windows_end,

    /// Set the tab title for a specific tmux window. Emitted in
    /// response to `%window-renamed` notifications.
    set_tab_title: struct {
        tmux_window_id: usize,
        title: []const u8,
    },

    /// Set the Ghostty window title from the tmux session name.
    /// Emitted in response to `%session-renamed` notifications.
    set_window_title: struct {
        title: []const u8,
    },
};

/// Payload for the `tmux_reconcile` action. Contains an ordered list
/// of reconcile operations and an arena that owns all referenced data
/// (layout trees, ID slices). The receiver must call `deinit` after
/// processing.
///
/// Heap-allocated and pointer-passed; the receiver frees via `deinit`.
pub const TmuxReconcilePayload = struct {
    /// Allocator used to create this struct itself.
    alloc: Allocator,

    /// Arena owning all op-referenced data (layout trees, ID slices).
    arena: ArenaAllocator,

    /// Ordered list of reconcile operations.
    ops: []const TmuxReconcileOp,

    pub fn deinit(self: *TmuxReconcilePayload) void {
        // Drop the payload holds taken in planTmuxReconcile BEFORE freeing the
        // arena that owns the ops. The focus/title payload builders carry no
        // ensure_pane op, so this releases nothing for them. ROOTSHELL-TMUX
        // (id=viewer-snapshot-refcount)
        for (self.ops) |op| switch (op) {
            .ensure_pane => |ep| if (ep.viewer_pane) |pane| pane.releaseSnapshotRef(),
            else => {},
        };
        const alloc = self.alloc;
        self.arena.deinit();
        alloc.destroy(self);
    }
};

/// Build an ordered list of reconcile ops from a tmux topology snapshot.
///
/// The planner emits: sync_windows_begin, then for each window
/// (ensure_window, ensure_pane for each leaf pane, set_layout,
/// set_tab_title), then prune_absent, sync_windows_end.
///
/// The returned payload is heap-allocated and owns all referenced data
/// via its arena. The caller must call `deinit` after processing.
///
/// This is a pure function operating on snapshot data — no Surface
/// instance needed — making it straightforward to unit test.
pub fn planTmuxReconcile(
    alloc: Allocator,
    windows: []const terminal.tmux.Viewer.Window,
    // ROOTSHELL-TMUX (id=snapshot-pane-refs): captured (pane_id -> *Pane)
    // pointers from the snapshot arena, NOT a live viewer map. Runs on the app
    // thread, so reading the live map here would race the gateway IO thread
    // reallocating/freeing its backing.
    panes: []const PaneRef,
    // ROOTSHELL-TMUX (id=plan-reconcile-titles): resolved tab title per window
    // (parallel to `windows`), carrying the `#T`-wins precedence from the
    // snapshot. Used for the `set_tab_title` op instead of the bare window name.
    titles: []const []const u8,
) Allocator.Error!*TmuxReconcilePayload {
    std.debug.assert(titles.len == windows.len);
    var arena: ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // Pre-count ops: 1 begin + per-window(1 ensure_window + N panes + 1 set_layout + 1 set_tab_title) +
    // 1 prune_absent + 1 end = 3 + sum(1 + pane_count + 1 + 1)
    var total_panes: usize = 0;
    for (windows) |window| {
        total_panes += countPanesInLayout(window.layout);
    }
    const op_count = 3 + windows.len * 3 + total_panes;
    const ops = try arena_alloc.alloc(TmuxReconcileOp, op_count);

    // Collect all window and pane IDs for the prune set
    const window_ids = try arena_alloc.alloc(usize, windows.len);
    const pane_ids = try arena_alloc.alloc(usize, total_panes);

    var op_idx: usize = 0;
    var pane_idx: usize = 0;

    // sync_windows_begin
    ops[op_idx] = .sync_windows_begin;
    op_idx += 1;

    for (windows, 0..) |window, wi| {
        window_ids[wi] = window.id;

        // ensure_window
        ops[op_idx] = .{ .ensure_window = .{
            .tmux_window_id = window.id,
            .width = window.width,
            .height = window.height,
            .index = window.index,
        } };
        op_idx += 1;

        // ensure_pane for each leaf
        const pane_start = pane_idx;
        collectPaneIds(window.layout, pane_ids, &pane_idx);

        for (pane_ids[pane_start..pane_idx]) |pid| {
            const pane_ptr: ?*terminal.tmux.Viewer.Pane = lookupPaneRef(panes, pid);
            ops[op_idx] = .{ .ensure_pane = .{
                .tmux_window_id = window.id,
                .pane_id = pid,
                .viewer_terminal = if (pane_ptr) |pp| &pp.terminal else null,
                .viewer_pane = pane_ptr,
            } };
            op_idx += 1;
        }

        // set_layout — clone the layout into the arena so it outlives the snapshot
        const layout_ptr = try arena_alloc.create(terminal.tmux.Layout);
        layout_ptr.* = try window.layout.clone(arena_alloc);

        ops[op_idx] = .{ .set_layout = .{
            .tmux_window_id = window.id,
            .layout = layout_ptr,
            // When zoomed, tmux shows the window's active pane fullscreen.
            // ROOTSHELL-TMUX (id=tmux-zoom)
            .zoomed_pane_id = if (window.zoomed) window.active_pane_id else 0,
        } };
        op_idx += 1;

        // set_tab_title — use the snapshot's resolved title (active-pane `#T`
        // wins, window name `#W` is the fallback). ROOTSHELL-TMUX
        // (id=plan-reconcile-set-title): NOT `window.name` directly — that
        // would clobber inactive windows' `#T` titles on every topology
        // rebuild, and tmux won't re-send an unchanged pane title to fix it.
        const title_copy = try arena_alloc.dupe(u8, titles[wi]);
        ops[op_idx] = .{ .set_tab_title = .{
            .tmux_window_id = window.id,
            .title = title_copy,
        } };
        op_idx += 1;
    }

    // Sort ID slices for binary search in prune_absent
    std.mem.sort(usize, window_ids, {}, std.sort.asc(usize));
    std.mem.sort(usize, pane_ids, {}, std.sort.asc(usize));

    // prune_absent
    ops[op_idx] = .{ .prune_absent = .{
        .window_ids = window_ids,
        .pane_ids = pane_ids,
    } };
    op_idx += 1;

    // sync_windows_end
    ops[op_idx] = .sync_windows_end;
    op_idx += 1;

    std.debug.assert(op_idx == op_count);

    const payload = try alloc.create(TmuxReconcilePayload);
    payload.* = .{
        .alloc = alloc,
        .arena = arena,
        .ops = ops,
    };

    // Take a payload hold on every pane this op batch carries a raw pointer to,
    // now that the payload is fully built (no fallible step follows). The payload
    // outlives the snapshot — it rides the tmux_reconcile action to the app /
    // Swift apply, which dereferences viewer_pane / viewer_terminal there — so the
    // hold must persist until the payload is freed (`TmuxReconcilePayload.deinit`
    // releases it). ROOTSHELL-TMUX (id=viewer-snapshot-refcount)
    for (ops) |op| switch (op) {
        .ensure_pane => |ep| if (ep.viewer_pane) |pane| pane.acquireSnapshotRef(),
        else => {},
    };
    return payload;
}

/// Count the number of leaf panes in a layout tree.
/// Look up a captured viewer pane pointer by tmux pane ID. Linear scan — a
/// tmux session has only a handful of panes, and the slice is the snapshot's
/// immutable capture, not the live (concurrently-mutated) viewer map.
/// ROOTSHELL-TMUX (id=snapshot-pane-refs)
fn lookupPaneRef(panes: []const PaneRef, id: usize) ?*terminal.tmux.Viewer.Pane {
    for (panes) |ref| {
        if (ref.id == id) return ref.pane;
    }
    return null;
}

fn countPanesInLayout(layout: terminal.tmux.Layout) usize {
    switch (layout.content) {
        .pane => return 1,
        .horizontal, .vertical => |children| {
            var count: usize = 0;
            for (children) |child| {
                count += countPanesInLayout(child);
            }
            return count;
        },
    }
}

/// Collect all leaf pane IDs from a layout tree into a pre-allocated slice.
fn collectPaneIds(layout: terminal.tmux.Layout, ids: []usize, idx: *usize) void {
    switch (layout.content) {
        .pane => |pane_id| {
            ids[idx.*] = pane_id;
            idx.* += 1;
        },
        .horizontal, .vertical => |children| {
            for (children) |child| {
                collectPaneIds(child, ids, idx);
            }
        },
    }
}

/// Build a minimal reconcile payload containing a single `.set_focus`
/// op for the given tmux window and pane. Used when focus changes
/// without a topology change (i.e. `%window-pane-changed`).
///
/// Reuses the existing `TmuxReconcilePayload` / `tmux_reconcile`
/// action so the apprt handler doesn't need a separate code path.
///
/// This is a pure function — no Surface instance needed — making it
/// straightforward to unit test.
pub fn focusTmuxReconcile(
    alloc: Allocator,
    window_id: usize,
    pane_id: usize,
) Allocator.Error!*TmuxReconcilePayload {
    var arena: ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const ops = try arena_alloc.alloc(TmuxReconcileOp, 1);
    ops[0] = .{ .set_focus = .{
        .tmux_window_id = window_id,
        .pane_id = pane_id,
    } };

    const payload = try alloc.create(TmuxReconcilePayload);
    payload.* = .{
        .alloc = alloc,
        .arena = arena,
        .ops = ops,
    };
    return payload;
}

/// Build a minimal reconcile payload containing a single title op.
/// Used for `%window-renamed` (tab title, `window_id` set) and
/// `%session-renamed` (window title, `window_id` null).
///
/// The title string is copied into the payload's arena so the caller
/// can discard the source after this returns.
pub fn titleTmuxReconcile(
    alloc: Allocator,
    tmux_window_id: ?usize,
    title: []const u8,
) Allocator.Error!*TmuxReconcilePayload {
    var arena: ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const title_copy = try arena_alloc.dupe(u8, title);
    const ops = try arena_alloc.alloc(TmuxReconcileOp, 1);

    if (tmux_window_id) |wid| {
        ops[0] = .{ .set_tab_title = .{
            .tmux_window_id = wid,
            .title = title_copy,
        } };
    } else {
        ops[0] = .{ .set_window_title = .{
            .title = title_copy,
        } };
    }

    const payload = try alloc.create(TmuxReconcilePayload);
    payload.* = .{
        .alloc = alloc,
        .arena = arena,
        .ops = ops,
    };
    return payload;
}

test "planTmuxReconcile uses pane-title precedence from the snapshot" {
    // ROOTSHELL-TMUX (id=test-plan-reconcile-title-precedence): a topology
    // rebuild must preserve the active-pane title (`#T`) for EVERY window, not
    // just the active one — window A has a cached pane title, window B does not.
    const testing = std.testing;
    const alloc = testing.allocator;
    const Snapshot = @import("apprt/surface_tmux.zig").TmuxTopologySnapshot;

    // Two single-pane windows: A id=1 name="zsh", B id=2 name="bash".
    const leaf_a: terminal.tmux.Layout = .{ .width = 80, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 1 } };
    const leaf_b: terminal.tmux.Layout = .{ .width = 80, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 2 } };
    const windows = [_]terminal.tmux.Viewer.Window{
        .{ .id = 1, .width = 80, .height = 24, .layout = leaf_a, .name = "zsh" },
        .{ .id = 2, .width = 80, .height = 24, .layout = leaf_b, .name = "bash" },
    };

    // Pane-title cache: only window 1 has a title set (e.g. an app set `#T`).
    var pane_titles: terminal.tmux.Viewer.PaneTitlesMap = .empty;
    defer {
        var it = pane_titles.iterator();
        while (it.next()) |e| alloc.free(e.value_ptr.*);
        pane_titles.deinit(alloc);
    }
    try pane_titles.put(alloc, 1, try alloc.dupe(u8, "vim - main.zig"));

    const snapshot = try Snapshot.initFromWindows(alloc, &windows, null, &pane_titles);
    defer snapshot.deinit();

    const payload = try planTmuxReconcile(alloc, snapshot.windows, snapshot.panes, snapshot.titles);
    defer payload.deinit();

    var title_for_1: ?[]const u8 = null;
    var title_for_2: ?[]const u8 = null;
    for (payload.ops) |op| {
        switch (op) {
            .set_tab_title => |t| {
                if (t.tmux_window_id == 1) title_for_1 = t.title;
                if (t.tmux_window_id == 2) title_for_2 = t.title;
            },
            else => {},
        }
    }

    // Window 1: pane title wins. Window 2: falls back to the window name.
    try testing.expectEqualStrings("vim - main.zig", title_for_1 orelse return error.MissingTitle);
    try testing.expectEqualStrings("bash", title_for_2 orelse return error.MissingTitle);
}

test {
    std.testing.refAllDecls(@This());
}
