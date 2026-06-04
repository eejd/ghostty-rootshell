//! Integration tests for the tmux control mode pipeline.
//!
//! These tests spawn a real tmux subprocess in control mode and validate
//! the full parser → viewer → action pipeline against actual tmux output.
//! They require tmux to be installed on the host system.
//!
//! The tests are designed to be hermetic: each test creates a unique tmux
//! session, exercises it, and tears it down in a defer. If tmux is not
//! available, the tests are silently skipped (not failed).

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const control = @import("control.zig");
const Viewer = @import("viewer.zig").Viewer;
const Screen = @import("../Screen.zig");

const log = std.log.scoped(.terminal_tmux_integration);

/// Helper that drives a tmux control-mode subprocess. Owns the child
/// process, pipes, and the control parser that consumes raw bytes.
const TmuxHarness = struct {
    child: std.process.Child,
    parser: control.Parser,
    viewer: Viewer,
    session_name: []const u8,

    const InitError = error{
        TmuxNotAvailable,
    } || std.process.Child.SpawnError || std.mem.Allocator.Error;

    fn init(alloc: std.mem.Allocator, session_name: []const u8) InitError!TmuxHarness {
        // Start tmux in control mode with a new detached session, then
        // attach to it. We use -x/-y to set a known terminal size.
        var child: std.process.Child = .init(
            &.{
                "tmux",
                "-C",
                "new-session",
                "-d",
                "-s",
                session_name,
                "-x",
                "80",
                "-y",
                "24",
                ";",
                "attach-session",
                "-t",
                session_name,
            },
            alloc,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            return switch (err) {
                error.FileNotFound => error.TmuxNotAvailable,
                else => err,
            };
        };

        const viewer = try Viewer.init(alloc, 80, 24);

        return .{
            .child = child,
            .parser = .{ .buffer = .init(alloc) },
            .viewer = viewer,
            .session_name = session_name,
        };
    }

    fn deinit(self: *TmuxHarness) void {
        // Kill only our test session, never the whole server
        if (self.child.stdin) |stdin| {
            // Best-effort: ask tmux to kill just our session.
            // Use allocPrint since session_name is runtime-known.
            const cmd = std.fmt.allocPrint(
                testing.allocator,
                "kill-session -t {s}\n",
                .{self.session_name},
            ) catch null;
            if (cmd) |c| {
                stdin.writeAll(c) catch {};
                testing.allocator.free(c);
            }
        }

        // Close stdin to signal EOF
        if (self.child.stdin) |stdin| {
            stdin.close();
            self.child.stdin = null;
        }

        self.viewer.deinit();
        self.parser.deinit();

        _ = self.child.wait() catch {};
    }

    /// Read available bytes from tmux stdout with a timeout.
    /// Returns the number of bytes read, or 0 if timeout/EOF.
    fn readWithTimeout(self: *TmuxHarness, buf: []u8, timeout_ms: u32) !usize {
        const stdout_fd = self.child.stdout.?.handle;

        // Use poll to wait for data with timeout
        var fds = [1]posix.pollfd{
            .{
                .fd = stdout_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const ready = try posix.poll(&fds, @intCast(timeout_ms));
        if (ready == 0) return 0; // timeout

        if (fds[0].revents & posix.POLL.HUP != 0) return 0; // EOF

        return self.child.stdout.?.read(buf) catch |err| {
            log.warn("read error: {}", .{err});
            return 0;
        };
    }

    /// Feed bytes from tmux through the parser, collecting notifications.
    /// Returns all notifications found in this batch of bytes.
    fn feedBytes(self: *TmuxHarness, bytes: []const u8) !std.ArrayList(control.Notification) {
        var notifications: std.ArrayList(control.Notification) = .empty;
        for (bytes) |byte| {
            if (try self.parser.put(byte)) |notification| {
                try notifications.append(testing.allocator, notification);
            }
        }
        return notifications;
    }

    /// Drive the full startup sequence: read from tmux, feed through
    /// parser and viewer, send commands back, until the viewer reaches
    /// the command_queue state (i.e., windows are discovered and pane
    /// captures are complete).
    fn driveStartup(self: *TmuxHarness, timeout_ms: u32) !bool {
        const deadline = std.time.milliTimestamp() + timeout_ms;
        var buf: [4096]u8 = undefined;
        var saw_windows = false;

        while (std.time.milliTimestamp() < deadline) {
            const remaining_ms: u32 = @intCast(@max(1, deadline - std.time.milliTimestamp()));
            const n = try self.readWithTimeout(&buf, remaining_ms);
            if (n == 0) continue;

            var notifications = try self.feedBytes(buf[0..n]);
            defer notifications.deinit(testing.allocator);

            for (notifications.items) |notification| {
                const actions = self.viewer.next(.{ .tmux = notification });

                for (actions) |action| {
                    if (action == .command) {
                        try self.sendCommand(action.command);
                    }
                    if (action == .windows) {
                        saw_windows = true;
                    }
                }
            }

            // Check if the viewer has settled (command queue is empty
            // and we've seen windows). The viewer is in command_queue
            // state when startup is complete.
            if (saw_windows and self.viewer.command_queue.empty()) {
                return true;
            }
        }

        return false;
    }

    /// Send a raw command string to tmux's stdin.
    fn sendCommand(self: *TmuxHarness, cmd: []const u8) !void {
        if (self.child.stdin) |stdin| {
            try stdin.writeAll(cmd);
        }
    }
};

// ─── Integration Tests ───────────────────────────────────────────────

test "integration: connect and discover windows" {
    // Validates the full startup sequence: connect to tmux in control
    // mode, parse the initial output, drive the viewer through startup,
    // and verify that we discover windows and panes.
    var harness = TmuxHarness.init(testing.allocator, "ghostty_test_connect") catch |err| {
        if (err == error.TmuxNotAvailable) return error.SkipZigTest;
        return err;
    };
    defer harness.deinit();

    // Drive the full startup sequence
    const started = try harness.driveStartup(10_000);
    try testing.expect(started);

    // After startup, we should have at least one window
    try testing.expect(harness.viewer.windows.items.len > 0);

    // The window should have a valid ID and dimensions
    const window = harness.viewer.windows.items[0];
    try testing.expect(window.width > 0);
    try testing.expect(window.height > 0);

    // We should have at least one pane
    try testing.expect(harness.viewer.panes.count() > 0);

    // The tmux version should be captured
    try testing.expect(harness.viewer.tmux_version.len > 0);
}

test "integration: output routing" {
    // Validates that %output notifications from tmux are correctly
    // parsed and processed into the viewer's pane terminal.
    var harness = TmuxHarness.init(testing.allocator, "ghostty_test_output") catch |err| {
        if (err == error.TmuxNotAvailable) return error.SkipZigTest;
        return err;
    };
    defer harness.deinit();

    const started = try harness.driveStartup(10_000);
    try testing.expect(started);

    // Send a command to tmux that will produce output
    try harness.sendCommand("send-keys 'echo GHOSTTY_TEST_MARKER' Enter\n");

    // Drive until we see the marker in a pane terminal
    const deadline = std.time.milliTimestamp() + 5_000;
    var buf: [4096]u8 = undefined;
    var found_marker = false;

    while (std.time.milliTimestamp() < deadline) {
        const remaining_ms: u32 = @intCast(@max(1, deadline - std.time.milliTimestamp()));
        const n = try harness.readWithTimeout(&buf, remaining_ms);
        if (n == 0) continue;

        var notifications = try harness.feedBytes(buf[0..n]);
        defer notifications.deinit(testing.allocator);

        for (notifications.items) |notification| {
            const actions = harness.viewer.next(.{ .tmux = notification });
            for (actions) |action| {
                switch (action) {
                    .command => |cmd| try harness.sendCommand(cmd),
                    else => {},
                }
            }
        }

        // Check all pane terminals for the marker string
        var pane_iter = harness.viewer.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane: *Viewer.Pane = entry.value_ptr.*;
            const screen: *Screen = pane.terminal.screens.active;
            const str = screen.dumpStringAlloc(
                testing.allocator,
                .{ .active = .{} },
            ) catch continue;
            defer testing.allocator.free(str);
            if (std.mem.indexOf(u8, str, "GHOSTTY_TEST_MARKER") != null) {
                found_marker = true;
                break;
            }
        }

        if (found_marker) break;
    }

    try testing.expect(found_marker);
}

test "integration: topology change on split" {
    // Validates that splitting a pane triggers a %layout-change
    // notification that is correctly parsed and produces updated
    // window topology with the correct number of panes.
    var harness = TmuxHarness.init(testing.allocator, "ghostty_test_split") catch |err| {
        if (err == error.TmuxNotAvailable) return error.SkipZigTest;
        return err;
    };
    defer harness.deinit();

    const started = try harness.driveStartup(10_000);
    try testing.expect(started);

    const initial_pane_count = harness.viewer.panes.count();
    try testing.expect(initial_pane_count >= 1);

    // Split the pane horizontally
    try harness.sendCommand("split-window -h\n");

    // Drive until we see a windows action (layout change triggers
    // a windows update with the new topology)
    const deadline = std.time.milliTimestamp() + 5_000;
    var buf: [4096]u8 = undefined;
    var saw_topology_change = false;

    while (std.time.milliTimestamp() < deadline) {
        const remaining_ms: u32 = @intCast(@max(1, deadline - std.time.milliTimestamp()));
        const n = try harness.readWithTimeout(&buf, remaining_ms);
        if (n == 0) continue;

        var notifications = try harness.feedBytes(buf[0..n]);
        defer notifications.deinit(testing.allocator);

        for (notifications.items) |notification| {
            const actions = harness.viewer.next(.{ .tmux = notification });
            for (actions) |action| {
                switch (action) {
                    .command => |cmd| try harness.sendCommand(cmd),
                    .windows => {
                        saw_topology_change = true;
                    },
                    else => {},
                }
            }
        }

        // After the split, we need to let the viewer finish processing
        // capture-pane commands for the new pane
        if (saw_topology_change and harness.viewer.command_queue.empty()) break;
    }

    try testing.expect(saw_topology_change);

    // After the split, we should have more panes than before
    try testing.expect(harness.viewer.panes.count() > initial_pane_count);

    // The window layout should now be a split (not a single pane)
    const window = harness.viewer.windows.items[0];
    try testing.expect(window.layout.content != .pane);
}

test "integration: session disconnect produces exit" {
    // Validates that killing the test session causes the control mode
    // connection to close, and the viewer handles it gracefully
    // without crashing. Uses kill-session (not kill-server) to avoid
    // destroying any other tmux sessions on the host.
    var harness = TmuxHarness.init(testing.allocator, "ghostty_test_disconnect") catch |err| {
        if (err == error.TmuxNotAvailable) return error.SkipZigTest;
        return err;
    };
    defer harness.deinit();

    const started = try harness.driveStartup(10_000);
    try testing.expect(started);

    // Kill our test session — this should cause the control mode
    // connection to close with a %exit or EOF.
    try harness.sendCommand("kill-session -t ghostty_test_disconnect\n");

    // Drive and see what happens — we should either get an exit
    // action or the pipe should close cleanly.
    const deadline = std.time.milliTimestamp() + 5_000;
    var buf: [4096]u8 = undefined;
    var saw_exit = false;
    var pipe_closed = false;

    while (std.time.milliTimestamp() < deadline) {
        const remaining_ms: u32 = @intCast(@max(1, deadline - std.time.milliTimestamp()));
        const n = try harness.readWithTimeout(&buf, remaining_ms);
        if (n == 0) {
            pipe_closed = true;
            break;
        }

        var notifications = try harness.feedBytes(buf[0..n]);
        defer notifications.deinit(testing.allocator);

        for (notifications.items) |notification| {
            if (notification == .exit) {
                saw_exit = true;
                _ = harness.viewer.next(.{ .tmux = notification });
                break;
            }

            const actions = harness.viewer.next(.{ .tmux = notification });
            for (actions) |action| {
                if (action == .exit) saw_exit = true;
            }
        }

        if (saw_exit) break;
    }

    // Either we got an explicit exit or the pipe closed
    try testing.expect(saw_exit or pipe_closed);
}

test "integration: focus change on pane switch" {
    // Validates that switching the active pane in tmux produces
    // a focus action from the viewer.
    var harness = TmuxHarness.init(testing.allocator, "ghostty_test_focus") catch |err| {
        if (err == error.TmuxNotAvailable) return error.SkipZigTest;
        return err;
    };
    defer harness.deinit();

    const started = try harness.driveStartup(10_000);
    try testing.expect(started);

    // Split the pane first so we have something to switch to
    try harness.sendCommand("split-window -h\n");

    // Drive until split is complete
    var deadline = std.time.milliTimestamp() + 5_000;
    var buf: [4096]u8 = undefined;
    var split_done = false;

    while (std.time.milliTimestamp() < deadline) {
        const remaining_ms: u32 = @intCast(@max(1, deadline - std.time.milliTimestamp()));
        const n = try harness.readWithTimeout(&buf, remaining_ms);
        if (n == 0) continue;

        var notifications = try harness.feedBytes(buf[0..n]);
        defer notifications.deinit(testing.allocator);

        for (notifications.items) |notification| {
            const actions = harness.viewer.next(.{ .tmux = notification });
            for (actions) |action| {
                if (action == .command) try harness.sendCommand(action.command);
                if (action == .windows) split_done = true;
            }
        }

        if (split_done and harness.viewer.command_queue.empty()) break;
    }

    try testing.expect(split_done);

    // Switch to the other pane
    try harness.sendCommand("select-pane -t :.+\n");

    // Drive until we see a focus action
    deadline = std.time.milliTimestamp() + 5_000;
    var saw_focus = false;
    var focus_pane_id: ?usize = null;

    while (std.time.milliTimestamp() < deadline) {
        const remaining_ms: u32 = @intCast(@max(1, deadline - std.time.milliTimestamp()));
        const n = try harness.readWithTimeout(&buf, remaining_ms);
        if (n == 0) continue;

        var notifications = try harness.feedBytes(buf[0..n]);
        defer notifications.deinit(testing.allocator);

        for (notifications.items) |notification| {
            const actions = harness.viewer.next(.{ .tmux = notification });
            for (actions) |action| {
                switch (action) {
                    .command => |cmd| try harness.sendCommand(cmd),
                    .focus => |f| {
                        saw_focus = true;
                        focus_pane_id = f.pane_id;
                    },
                    else => {},
                }
            }
        }

        if (saw_focus) break;
    }

    try testing.expect(saw_focus);
    try testing.expect(focus_pane_id != null);
    // The focused pane should be a known pane
    try testing.expect(harness.viewer.panes.contains(focus_pane_id.?));
}
