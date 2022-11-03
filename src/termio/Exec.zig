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
const renderer = @import("../renderer.zig");

const log = std.log.scoped(.io_exec);

/// This is the pty fd created for the subcommand.
pty: Pty,

/// This is the container for the subcommand.
command: Command,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminal.Terminal,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: terminal.Stream(StreamHandler),

/// The shared render state
renderer_state: *renderer.State,

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
        .terminal_stream = undefined,
        .renderer_state = opts.renderer_state,
    };
}

pub fn deinit(self: *Exec, alloc: Allocator) void {
    // Deinitialize the pty. This closes the pty handles. This should
    // cause a close in the our subprocess so just wait for that.
    self.pty.deinit();
    _ = self.command.wait() catch |err|
        log.err("error waiting for command to exit: {}", .{err});

    // Clean up our other members
    self.terminal.deinit(alloc);
}

pub fn threadEnter(self: *Exec, loop: libuv.Loop) !ThreadData {
    // Get a copy to our allocator
    const alloc_ptr = loop.getData(Allocator).?;
    const alloc = alloc_ptr.*;

    // Setup our data that is used for callbacks
    var ev_data_ptr = try alloc.create(EventData);
    errdefer alloc.destroy(ev_data_ptr);

    // Read data
    var stream = try libuv.Tty.init(alloc, loop, self.pty.master);
    errdefer stream.deinit(alloc);
    stream.setData(ev_data_ptr);
    try stream.readStart(ttyReadAlloc, ttyRead);

    // Setup our event data before we start
    ev_data_ptr.* = .{
        .read_arena = std.heap.ArenaAllocator.init(alloc),
        .renderer_state = self.renderer_state,
        .data_stream = stream,
        .terminal_stream = .{
            .handler = .{
                .terminal = &self.terminal,
            },
        },
    };
    errdefer ev_data_ptr.deinit();

    // Return our data
    return ThreadData{
        .alloc = alloc,
        .ev = ev_data_ptr,
    };
}

pub fn threadExit(self: *Exec, data: ThreadData) void {
    _ = self;
    _ = data;
}

const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The data that is attached to the callbacks.
    ev: *EventData,

    pub fn deinit(self: *ThreadData) void {
        self.ev.deinit();
        self.alloc.destroy(self.ev);
        self.* = undefined;
    }
};

const EventData = struct {
    /// This is the arena allocator used for IO read buffers. Since we use
    /// libuv under the covers, this lets us rarely heap allocate since we're
    /// usually just reusing buffers from this.
    read_arena: std.heap.ArenaAllocator,

    /// The stream parser. This parses the stream of escape codes and so on
    /// from the child process and calls callbacks in the stream handler.
    terminal_stream: terminal.Stream(StreamHandler),

    /// The shared render state
    renderer_state: *renderer.State,

    /// The data stream is the main IO for the pty.
    data_stream: libuv.Tty,

    pub fn deinit(self: *EventData) void {
        self.read_arena.deinit();

        // Stop our data stream
        self.data_stream.readStop();
        self.data_stream.close((struct {
            fn callback(h: *libuv.Tty) void {
                const handle_alloc = h.loop().getData(Allocator).?.*;
                h.deinit(handle_alloc);
            }
        }).callback);
    }
};

fn ttyReadAlloc(t: *libuv.Tty, size: usize) ?[]u8 {
    const ev = t.getData(EventData) orelse return null;
    const alloc = ev.read_arena.allocator();
    return alloc.alloc(u8, size) catch null;
}

fn ttyRead(t: *libuv.Tty, n: isize, buf: []const u8) void {
    const ev = t.getData(EventData).?;
    defer {
        const alloc = ev.read_arena.allocator();
        alloc.free(buf);
    }

    // log.info("DATA: {d}", .{n});
    // log.info("DATA: {any}", .{buf[0..@intCast(usize, n)]});

    // First check for errors in the case n is less than 0.
    libuv.convertError(@intCast(i32, n)) catch |err| {
        switch (err) {
            // ignore EOF because it should end the process.
            libuv.Error.EOF => {},
            else => log.err("read error: {}", .{err}),
        }

        return;
    };

    // We are modifying terminal state from here on out
    ev.renderer_state.mutex.lock();
    defer ev.renderer_state.mutex.unlock();

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible.
    ev.renderer_state.cursor.blink = false;
    // TODO
    // if (win.terminal_cursor.timer.isActive() catch false) {
    //     _ = win.terminal_cursor.timer.again() catch null;
    // }

    // Schedule a render
    // TODO
    //win.queueRender() catch unreachable;

    // Process the terminal data. This is an extremely hot part of the
    // terminal emulator, so we do some abstraction leakage to avoid
    // function calls and unnecessary logic.
    //
    // The ground state is the only state that we can see and print/execute
    // ASCII, so we only execute this hot path if we're already in the ground
    // state.
    //
    // Empirically, this alone improved throughput of large text output by ~20%.
    var i: usize = 0;
    const end = @intCast(usize, n);
    // TODO: re-enable this
    if (ev.terminal_stream.parser.state == .ground and false) {
        for (buf[i..end]) |c| {
            switch (terminal.parse_table.table[c][@enumToInt(terminal.Parser.State.ground)].action) {
                // Print, call directly.
                .print => ev.print(@intCast(u21, c)) catch |err|
                    log.err("error processing terminal data: {}", .{err}),

                // C0 execute, let our stream handle this one but otherwise
                // continue since we're guaranteed to be back in ground.
                .execute => ev.terminal_stream.execute(c) catch |err|
                    log.err("error processing terminal data: {}", .{err}),

                // Otherwise, break out and go the slow path until we're
                // back in ground. There is a slight optimization here where
                // could try to find the next transition to ground but when
                // I implemented that it didn't materially change performance.
                else => break,
            }

            i += 1;
        }
    }

    if (i < end) {
        ev.terminal_stream.nextSlice(buf[i..end]) catch |err|
            log.err("error processing terminal data: {}", .{err});
    }
}

const StreamHandler = struct {
    terminal: *terminal.Terminal,
};
