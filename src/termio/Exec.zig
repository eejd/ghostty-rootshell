//! Implementation of IO that uses child exec to talk to the child process.
pub const Exec = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const Pty = @import("../Pty.zig");
const terminal = @import("../terminal/main.zig");
const libuv = @import("libuv");

const log = std.log.scoped(.io_exec);

/// This is the pty fd created for the subcommand.
pty: Pty,

/// This is the container for the subcommand.
command: Command,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminal.Terminal,

/// Initialize the exec implementation. This will also start the child
/// process.
pub fn init(alloc: Allocator, opts: termio.Options) !Exec {
    // Create our pty
    var pty = try Pty.open(.{
        .ws_row = @intCast(u16, opts.grid_size.rows),
        .ws_col = @intCast(u16, opts.grid_size.columns),
        .ws_xpixel = @intCast(u16, opts.screen_size.width),
        .ws_ypixel = @intCast(u16, opts.screen_size.height),
    });
    errdefer pty.deinit();

    // Determine the path to the binary we're executing
    const path = (try Command.expandPath(alloc, opts.config.command orelse "sh")) orelse
        return error.CommandNotFound;
    defer alloc.free(path);

    // Set our env vars
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-256color");

    // Build our subcommand
    var cmd: Command = .{
        .path = path,
        .args = &[_][]const u8{path},
        .env = &env,
        .cwd = opts.config.@"working-directory",
        .pre_exec = (struct {
            fn callback(c: *Command) void {
                const p = c.getData(Pty) orelse unreachable;
                p.childPreExec() catch |err|
                    log.err("error initializing child: {}", .{err});
            }
        }).callback,
        .data = &pty,
    };
    // note: can't set these in the struct initializer because it
    // sets the handle to "0". Probably a stage1 zig bug.
    cmd.stdin = std.fs.File{ .handle = pty.slave };
    cmd.stdout = cmd.stdin;
    cmd.stderr = cmd.stdin;
    try cmd.start(alloc);
    log.info("started subcommand path={s} pid={?}", .{ path, cmd.pid });

    // Create our terminal
    var term = try terminal.Terminal.init(alloc, opts.grid_size.columns, opts.grid_size.rows);
    errdefer term.deinit(alloc);

    return Exec{
        .pty = pty,
        .command = cmd,
        .terminal = term,
    };
}

pub fn deinit(self: *Exec, alloc: Allocator) void {
    // Deinitialize the pty. This closes the pty handles. This should
    // cause a close in the our subprocess so just wait for that.
    self.pty.deinit();
    _ = self.command.wait() catch |err|
        log.err("error waiting for command to exit: {}", .{err});

    // Clean up the terminal state
    self.terminal.deinit(alloc);
}

pub fn threadEnter(self: *Exec, loop: libuv.Loop) !void {
    _ = self;
    _ = loop;
}

pub fn threadExit(self: *Exec) void {
    _ = self;
}
