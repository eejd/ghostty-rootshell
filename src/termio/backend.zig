// ROOTSHELL-TMUX: this upstream-shared file carries the fork's `tmux` termio
// backend variant in the Kind/Config/Backend/ThreadData unions, plus its switch
// arms. The backend implementation lives in the fork-owned termio/Tmux.zig. Grep
// "ROOTSHELL-TMUX" here for every hook. See docs/tmux-control-mode-fork.md.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const shell_integration = @import("shell_integration.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const Pty = @import("../pty.zig").Pty;
const ProcessInfo = @import("../pty.zig").ProcessInfo;

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// The kinds of backends.
pub const Kind = enum { exec, pipe, tmux }; // ROOTSHELL-TMUX (id=backend-kind): `tmux` variant

/// Configuration for the various backend types.
pub const Config = union(Kind) {
    /// Exec uses posix exec to run a command with a pty.
    exec: termio.Exec.Config,

    /// Pipe uses pipes instead of PTY for external I/O management
    pipe: termio.Pipe.Config,

    /// Tmux routes I/O through a tmux control mode connection that is
    /// owned by a parent terminal surface (the `tmux -CC` viewer-owner).
    tmux: termio.Tmux.Config, // ROOTSHELL-TMUX (id=backend-config-tmux)
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,
    pipe: termio.Pipe,
    tmux: termio.Tmux, // ROOTSHELL-TMUX (id=backend-tmux): switch arms below dispatch to the fork-owned termio/Tmux.zig backend

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
            .pipe => |*p| p.deinit(),
            .tmux => |*tmux| tmux.deinit(),
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
            .pipe => |*p| p.initTerminal(t),
            .tmux => |*tmux| tmux.initTerminal(t),
        }
    }

    pub fn threadEnter(
        self: *Backend,
        alloc: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.threadEnter(alloc, io, td),
            .pipe => |*p| try p.threadEnter(alloc, io, td),
            .tmux => |*tmux| try tmux.threadEnter(alloc, io, td),
        }
    }

    pub fn threadExit(self: *Backend, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(td),
            .pipe => |*p| p.threadExit(td),
            .tmux => |*tmux| tmux.threadExit(td),
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
            .pipe => |*p| try p.focusGained(td, focused),
            .tmux => |*tmux| try tmux.focusGained(td, focused),
        }
    }

    pub fn resize(
        self: *Backend,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.resize(grid_size, screen_size),
            .pipe => |*p| try p.resize(grid_size, screen_size),
            .tmux => |*tmux| try tmux.resize(grid_size, screen_size),
        }
    }

    pub fn queueWrite(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .pipe => |*p| try p.queueWrite(alloc, td, data, linefeed),
            .tmux => |*tmux| try tmux.queueWrite(alloc, td, data, linefeed),
        }
    }

    pub fn childExitedAbnormally(
        self: *Backend,
        gpa: Allocator,
        t: *terminal.Terminal,
        exit_code: u32,
        runtime_ms: u64,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
            .pipe => |*p| try p.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
            .tmux => |*tmux| try tmux.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
        }
    }

    /// Forward a raw command to the tmux control mode connection.
    /// No-op for the exec and pipe backends.
    pub fn tmuxCommand(self: *Backend, cmd: []const u8) void {
        switch (self.*) {
            .exec => {},
            .pipe => {},
            .tmux => |*tmux| tmux.tmuxCommand(cmd),
        }
    }

    /// Get information about the process(es) attached to the backend. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *Backend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (self.*) {
            .exec => |*exec| exec.getProcessInfo(info),
            .pipe => null,
            .tmux => null,
        };
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,
    pipe: termio.Pipe.ThreadData,
    tmux: termio.Tmux.ThreadData, // ROOTSHELL-TMUX (id=backend-threaddata-tmux)

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
            .pipe => |*p| p.deinit(alloc),
            .tmux => |*tmux| tmux.deinit(alloc),
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};
