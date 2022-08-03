//! Window represents a single OS window.
//!
//! NOTE(multi-window): This may be premature, but this abstraction is here
//! to pave the way One Day(tm) for multi-window support. At the time of
//! writing, we support exactly one window.
const Window = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Grid = @import("Grid.zig");
const glfw = @import("glfw");
const gl = @import("opengl.zig");
const libuv = @import("libuv/main.zig");
const Pty = @import("Pty.zig");
const Command = @import("Command.zig");
const SegmentedPool = @import("segmented_pool.zig").SegmentedPool;
const frame = @import("tracy/tracy.zig").frame;
const trace = @import("tracy/tracy.zig").trace;
const max_timer = @import("max_timer.zig");
const terminal = @import("terminal/main.zig");
const Config = @import("config.zig").Config;

const RenderTimer = max_timer.MaxTimer(renderTimerCallback);

const log = std.log.scoped(.window);

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// Allocator
alloc: Allocator,

/// The glfw window handle.
window: glfw.Window,

/// The glfw mouse cursor handle.
cursor: glfw.Cursor,

/// Whether the window is currently focused
focused: bool,

/// The terminal grid attached to this window.
grid: Grid,

/// The underlying pty for this window.
pty: Pty,

/// The command we're running for our tty.
command: Command,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid. This is connected back to
/// a renderer.
terminal: terminal.Terminal,

/// The stream parser.
terminal_stream: terminal.Stream(*Window),

/// Timer that blinks the cursor.
cursor_timer: libuv.Timer,
cursor_style: terminal.CursorStyle,

/// Render at least 60fps.
render_timer: RenderTimer,

/// The reader/writer stream for the pty.
pty_stream: libuv.Tty,

/// This is the pool of available (unused) write requests. If you grab
/// one from the pool, you must put it back when you're done!
write_req_pool: SegmentedPool(libuv.WriteReq.T, WRITE_REQ_PREALLOC) = .{},

/// The pool of available buffers for writing to the pty.
write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

/// Set this to true whenver an event occurs that we may want to wake up
/// the event loop. Only set this from the main thread.
wakeup: bool = false,

/// The app configuration
config: *const Config,

/// Window background color
bg_r: f32,
bg_g: f32,
bg_b: f32,
bg_a: f32,

/// Bracketed paste mode
bracketed_paste: bool = false,

/// Set to true for a single GLFW key/char callback cycle to cause the
/// char callback to ignore. GLFW seems to always do key followed by char
/// callbacks so we abuse that here. This is to solve an issue where commands
/// like such as "control-v" will write a "v" even if they're intercepted.
ignore_char: bool = false,

/// Create a new window. This allocates and returns a pointer because we
/// need a stable pointer for user data callbacks. Therefore, a stack-only
/// initialization is not currently possible.
pub fn create(alloc: Allocator, loop: libuv.Loop, config: *const Config) !*Window {
    var self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    // Create our window
    const window = try glfw.Window.create(640, 480, "ghostty", null, null, .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
        .cocoa_graphics_switching = builtin.os.tag == .macos,

        // We need to disable this for now since this causes all sorts
        // of artifacts and issues to debug. This probably SHOULD be re-enable
        // at some point but only when we're ready to debug.
        .cocoa_retina_framebuffer = false,
    });
    errdefer window.destroy();

    // NOTE(multi-window): We'll need to extract all the below into a
    // dedicated renderer and consider the multi-threading (or at the very
    // least: multi-OpenGL-context) implications. Since we don't support
    // multiple windows right now, we just do it all here.

    // Setup OpenGL
    try glfw.makeContextCurrent(window);
    try glfw.swapInterval(1);

    // Load OpenGL bindings
    const version = try gl.glad.load(glfw.getProcAddress);
    log.info("loaded OpenGL {}.{}", .{
        gl.glad.versionMajor(version),
        gl.glad.versionMinor(version),
    });

    // Culling, probably not necessary. We have to change the winding
    // order since our 0,0 is top-left.
    gl.c.glEnable(gl.c.GL_CULL_FACE);
    gl.c.glFrontFace(gl.c.GL_CW);

    // Blending for text
    gl.c.glEnable(gl.c.GL_BLEND);
    gl.c.glBlendFunc(gl.c.GL_SRC_ALPHA, gl.c.GL_ONE_MINUS_SRC_ALPHA);

    // Create our terminal grid with the initial window size
    const window_size = try window.getSize();
    var grid = try Grid.init(alloc, config);
    try grid.setScreenSize(.{ .width = window_size.width, .height = window_size.height });
    grid.background = .{
        .r = config.background.r,
        .g = config.background.g,
        .b = config.background.b,
    };
    grid.foreground = .{
        .r = config.foreground.r,
        .g = config.foreground.g,
        .b = config.foreground.b,
    };

    // Create our pty
    var pty = try Pty.open(.{
        .ws_row = @intCast(u16, grid.size.rows),
        .ws_col = @intCast(u16, grid.size.columns),
        .ws_xpixel = @intCast(u16, window_size.width),
        .ws_ypixel = @intCast(u16, window_size.height),
    });
    errdefer pty.deinit();

    // Create our child process
    const path = (try Command.expandPath(alloc, config.command orelse "sh")) orelse
        return error.CommandNotFound;
    defer alloc.free(path);

    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-256color");

    var cmd: Command = .{
        .path = path,
        .args = &[_][]const u8{path},
        .env = &env,
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
    log.debug("started subcommand path={s} pid={?}", .{ path, cmd.pid });

    // Read data
    var stream = try libuv.Tty.init(alloc, loop, pty.master);
    errdefer stream.deinit(alloc);
    stream.setData(self);
    try stream.readStart(ttyReadAlloc, ttyRead);

    // Create our terminal
    var term = try terminal.Terminal.init(alloc, grid.size.columns, grid.size.rows);
    errdefer term.deinit(alloc);

    // Setup a timer for blinking the cursor
    var timer = try libuv.Timer.init(alloc, loop);
    errdefer timer.deinit(alloc);
    errdefer timer.close(null);
    timer.setData(self);
    try timer.start(cursorTimerCallback, 600, 600);

    // Create the cursor
    const cursor = try glfw.Cursor.createStandard(.ibeam);
    errdefer cursor.destroy();
    try window.setCursor(cursor);

    self.* = .{
        .alloc = alloc,
        .window = window,
        .cursor = cursor,
        .focused = false,
        .grid = grid,
        .pty = pty,
        .command = cmd,
        .terminal = term,
        .terminal_stream = .{ .handler = self },
        .cursor_timer = timer,
        .cursor_style = .blinking_block,
        .render_timer = try RenderTimer.init(loop, self, 16, 64),
        .pty_stream = stream,
        .config = config,
        .bg_r = @intToFloat(f32, config.background.r) / 255.0,
        .bg_g = @intToFloat(f32, config.background.g) / 255.0,
        .bg_b = @intToFloat(f32, config.background.b) / 255.0,
        .bg_a = 1.0,
    };

    // Setup our callbacks and user data
    window.setUserPointer(self);
    window.setSizeCallback(sizeCallback);
    window.setCharCallback(charCallback);
    window.setKeyCallback(keyCallback);
    window.setFocusCallback(focusCallback);
    window.setRefreshCallback(refreshCallback);
    window.setScrollCallback(scrollCallback);

    return self;
}

pub fn destroy(self: *Window) void {
    // Deinitialize the pty. This closes the pty handles. This should
    // cause a close in the our subprocess so just wait for that.
    self.pty.deinit();
    _ = self.command.wait() catch |err|
        log.err("error waiting for command to exit: {}", .{err});

    self.terminal.deinit(self.alloc);
    self.grid.deinit();
    self.window.destroy();

    self.cursor_timer.close((struct {
        fn callback(t: *libuv.Timer) void {
            const alloc = t.loop().getData(Allocator).?.*;
            t.deinit(alloc);
        }
    }).callback);

    self.render_timer.deinit();

    // We have to dealloc our window in the close callback because
    // we can't free some of the memory associated with the window
    // until the stream is closed.
    self.pty_stream.readStop();
    self.pty_stream.close((struct {
        fn callback(t: *libuv.Tty) void {
            const win = t.getData(Window).?;
            const alloc = win.alloc;
            t.deinit(alloc);
            win.write_req_pool.deinit(alloc);
            win.write_buf_pool.deinit(alloc);
            win.alloc.destroy(win);
        }
    }).callback);

    // We can destroy the cursor right away. glfw will just revert any
    // windows using it to the default.
    self.cursor.destroy();
}

pub fn shouldClose(self: Window) bool {
    return self.window.shouldClose();
}

/// Queue a write to the pty.
fn queueWrite(self: *Window, data: []const u8) !void {
    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const req = try self.write_req_pool.get();
        const buf = try self.write_buf_pool.get();
        const end = @minimum(data.len, i + buf.len);
        std.mem.copy(u8, buf, data[i..end]);
        try self.pty_stream.write(
            .{ .req = req },
            &[1][]u8{buf[0..(end - i)]},
            ttyWrite,
        );

        i += end;
    }
}

/// Updates te style of the cursor.
fn updateCursorStyle(self: *Window, style: Grid.CursorStyle, blink: bool) !void {
    self.grid.cursor_style = style;
    self.grid.cursor_visible = !blink;

    if (blink) {
        try self.cursor_timer.start(
            cursorTimerCallback,
            0,
            self.cursor_timer.getRepeat(),
        );
    } else {
        try self.cursor_timer.stop();
    }

    // Always schedule a render when we change cursors
    try self.render_timer.schedule();
}

fn sizeCallback(window: glfw.Window, width: i32, height: i32) void {
    const tracy = trace(@src());
    defer tracy.end();

    // glfw gives us signed integers, but negative width/height is n
    // non-sensical so we use unsigned throughout, so assert.
    assert(width >= 0);
    assert(height >= 0);

    // Update our grid so that the projections on render are correct.
    const win = window.getUserPointer(Window) orelse return;
    win.grid.setScreenSize(.{
        .width = @intCast(u32, width),
        .height = @intCast(u32, height),
    }) catch |err| log.err("error updating grid screen size err={}", .{err});

    // Update the size of our terminal state
    win.terminal.resize(win.alloc, win.grid.size.columns, win.grid.size.rows) catch |err|
        log.err("error updating terminal size: {}", .{err});

    // Update the size of our pty
    win.pty.setSize(.{
        .ws_row = @intCast(u16, win.grid.size.rows),
        .ws_col = @intCast(u16, win.grid.size.columns),
        .ws_xpixel = @intCast(u16, width),
        .ws_ypixel = @intCast(u16, height),
    }) catch |err| log.err("error updating pty screen size err={}", .{err});

    // Update our viewport for this context to be the entire window
    gl.viewport(0, 0, width, height) catch |err|
        log.err("error updating OpenGL viewport err={}", .{err});

    // Draw
    win.render_timer.schedule() catch |err|
        log.err("error scheduling render timer in sizeCallback err={}", .{err});
}

fn charCallback(window: glfw.Window, codepoint: u21) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // Ignore if requested. See field docs for more information.
    if (win.ignore_char) {
        win.ignore_char = false;
        return;
    }

    // Write the character to the pty
    win.queueWrite(&[1]u8{@intCast(u8, codepoint)}) catch |err|
        log.err("error queueing write in charCallback err={}", .{err});
}

fn keyCallback(
    window: glfw.Window,
    key: glfw.Key,
    scancode: i32,
    action: glfw.Action,
    mods: glfw.Mods,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    _ = scancode;

    // Paste
    if (action == .press and mods.super and key == .v) {
        const win = window.getUserPointer(Window) orelse return;

        // Ignore this character for writing
        win.ignore_char = true;

        const data = glfw.getClipboardString() catch |err| {
            log.warn("error reading clipboard: {}", .{err});
            return;
        };

        if (data.len > 0) {
            if (win.bracketed_paste) win.queueWrite("\x1B[200~") catch |err|
                log.err("error queueing write in keyCallback err={}", .{err});
            win.queueWrite(data) catch |err|
                log.warn("error pasting clipboard: {}", .{err});
            if (win.bracketed_paste) win.queueWrite("\x1B[201~") catch |err|
                log.err("error queueing write in keyCallback err={}", .{err});
        }

        return;
    }

    //log.info("KEY {} {} {} {}", .{ key, scancode, mods, action });
    if (action == .press or action == .repeat) {
        const c: u8 = switch (key) {
            // Lots more of these:
            // https://www.physics.udel.edu/~watson/scen103/ascii.html
            .a => if (mods.control and !mods.shift) 0x01 else return,
            .b => if (mods.control and !mods.shift) 0x02 else return,
            .c => if (mods.control and !mods.shift) 0x03 else return,
            .d => if (mods.control and !mods.shift) 0x04 else return,
            .e => if (mods.control and !mods.shift) 0x05 else return,
            .f => if (mods.control and !mods.shift) 0x06 else return,
            .g => if (mods.control and !mods.shift) 0x07 else return,
            .h => if (mods.control and !mods.shift) 0x08 else return,
            .i => if (mods.control and !mods.shift) 0x09 else return,
            .j => if (mods.control and !mods.shift) 0x0A else return,
            .k => if (mods.control and !mods.shift) 0x0B else return,
            .l => if (mods.control and !mods.shift) 0x0C else return,
            .m => if (mods.control and !mods.shift) 0x0D else return,
            .n => if (mods.control and !mods.shift) 0x0E else return,
            .o => if (mods.control and !mods.shift) 0x0F else return,
            .p => if (mods.control and !mods.shift) 0x10 else return,
            .q => if (mods.control and !mods.shift) 0x11 else return,
            .r => if (mods.control and !mods.shift) 0x12 else return,
            .s => if (mods.control and !mods.shift) 0x13 else return,
            .t => if (mods.control and !mods.shift) 0x14 else return,
            .u => if (mods.control and !mods.shift) 0x15 else return,
            .v => if (mods.control and !mods.shift) 0x16 else return,
            .w => if (mods.control and !mods.shift) 0x17 else return,
            .x => if (mods.control and !mods.shift) 0x18 else return,
            .y => if (mods.control and !mods.shift) 0x19 else return,
            .z => if (mods.control and !mods.shift) 0x1A else return,

            .backspace => 0x08,
            .enter => '\r',
            .tab => '\t',
            .escape => 0x1B,
            else => return,
        };

        const win = window.getUserPointer(Window) orelse return;
        win.queueWrite(&[1]u8{c}) catch |err|
            log.err("error queueing write in keyCallback err={}", .{err});
    }
}

fn focusCallback(window: glfw.Window, focused: bool) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // If we aren't changing focus state, do nothing. I don't think this
    // can happen but it costs very little to check.
    if (win.focused == focused) return;

    // We have to schedule a render because no matter what we're changing
    // the cursor.
    win.render_timer.schedule() catch unreachable;

    // Set our focused state on the window.
    win.focused = focused;

    if (focused) {
        win.wakeup = true;
        win.updateCursorStyle(
            Grid.CursorStyle.fromTerminal(win.cursor_style) orelse .box,
            win.cursor_style.blinking(),
        ) catch unreachable;
    } else {
        win.updateCursorStyle(.box_hollow, false) catch unreachable;
    }
}

fn refreshCallback(window: glfw.Window) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // The point of this callback is to schedule a render, so do that.
    win.render_timer.schedule() catch unreachable;
}

fn scrollCallback(window: glfw.Window, xoff: f64, yoff: f64) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    //log.info("SCROLL: {} {}", .{ xoff, yoff });
    _ = xoff;

    // Positive is up
    const sign: isize = if (yoff > 0) -1 else 1;
    const delta: isize = sign * @maximum(@divFloor(win.grid.size.rows, 15), 1);
    log.info("scroll: delta={}", .{delta});
    win.terminal.scrollViewport(.{ .delta = delta });

    // Schedule render since scrolling usually does something.
    // TODO(perf): we can only schedule render if we know scrolling
    // did something
    win.render_timer.schedule() catch unreachable;
}

fn cursorTimerCallback(t: *libuv.Timer) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = t.getData(Window) orelse return;
    win.grid.cursor_visible = !win.grid.cursor_visible;
    win.render_timer.schedule() catch unreachable;
}

fn ttyReadAlloc(t: *libuv.Tty, size: usize) ?[]u8 {
    const tracy = trace(@src());
    defer tracy.end();

    const alloc = t.loop().getData(Allocator).?.*;
    return alloc.alloc(u8, size) catch null;
}

fn ttyRead(t: *libuv.Tty, n: isize, buf: []const u8) void {
    const tracy = trace(@src());
    tracy.color(0xEAEA7F); // yellow-ish
    defer tracy.end();

    const win = t.getData(Window).?;
    defer win.alloc.free(buf);

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

    // Whenever a character is typed, we ensure the cursor is visible
    // and we restart the cursor timer.
    win.grid.cursor_visible = true;
    if (win.cursor_timer.isActive() catch false) {
        _ = win.cursor_timer.again() catch null;
    }

    // Schedule a render
    win.render_timer.schedule() catch unreachable;

    // Process the terminal data
    win.terminal_stream.nextSlice(buf[0..@intCast(usize, n)]) catch |err|
        log.err("error processing terminal data: {}", .{err});
}

fn ttyWrite(req: *libuv.WriteReq, status: i32) void {
    const tracy = trace(@src());
    defer tracy.end();

    const tty = req.handle(libuv.Tty).?;
    const win = tty.getData(Window).?;
    win.write_req_pool.put();
    win.write_buf_pool.put();

    libuv.convertError(status) catch |err|
        log.err("write error: {}", .{err});

    //log.info("WROTE: {d}", .{status});
}

fn renderTimerCallback(t: *libuv.Timer) void {
    const tracy = trace(@src());
    tracy.color(0x006E7F); // blue-ish
    defer tracy.end();

    const win = t.getData(Window).?;

    // Calculate foreground and background colors
    const bg = win.grid.background;
    const fg = win.grid.foreground;
    defer {
        win.grid.background = bg;
        win.grid.foreground = fg;
    }
    if (win.terminal.modes.reverse_colors == 1) {
        win.grid.background = fg;
        win.grid.foreground = bg;
    }

    // Set our background
    const gl_bg: struct {
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    } = if (win.terminal.modes.reverse_colors == 1) .{
        .r = @intToFloat(f32, fg.r) / 255,
        .g = @intToFloat(f32, fg.g) / 255,
        .b = @intToFloat(f32, fg.b) / 255,
        .a = 1.0,
    } else .{
        .r = win.bg_r,
        .g = win.bg_g,
        .b = win.bg_b,
        .a = win.bg_a,
    };
    gl.clearColor(gl_bg.r, gl_bg.g, gl_bg.b, gl_bg.a);
    gl.clear(gl.c.GL_COLOR_BUFFER_BIT);

    // Update the cells for drawing
    win.grid.updateCells(win.terminal) catch |err|
        log.err("error calling updateCells in render timer err={}", .{err});

    // Update our texture if we have to
    win.grid.flushAtlas() catch |err|
        log.err("error calling flushAtlas in render timer err={}", .{err});

    // Render the grid
    win.grid.render() catch |err| {
        log.err("error rendering grid: {}", .{err});
        return;
    };

    // Swap
    win.window.swapBuffers() catch |err| {
        log.err("error swapping buffers: {}", .{err});
        return;
    };

    // Record our run
    win.render_timer.tick();
}

//-------------------------------------------------------------------
// Stream Callbacks

pub fn print(self: *Window, c: u21) !void {
    try self.terminal.print(c);
}

pub fn bell(self: Window) !void {
    _ = self;
    log.info("BELL", .{});
}

pub fn backspace(self: *Window) !void {
    self.terminal.backspace();
}

pub fn horizontalTab(self: *Window) !void {
    try self.terminal.horizontalTab();
}

pub fn linefeed(self: *Window) !void {
    self.terminal.linefeed();
}

pub fn carriageReturn(self: *Window) !void {
    self.terminal.carriageReturn();
}

pub fn setCursorLeft(self: *Window, amount: u16) !void {
    self.terminal.cursorLeft(amount);
}

pub fn setCursorRight(self: *Window, amount: u16) !void {
    self.terminal.cursorRight(amount);
}

pub fn setCursorDown(self: *Window, amount: u16) !void {
    self.terminal.cursorDown(amount);
}

pub fn setCursorUp(self: *Window, amount: u16) !void {
    self.terminal.cursorUp(amount);
}

pub fn setCursorCol(self: *Window, col: u16) !void {
    self.terminal.setCursorColAbsolute(col);
}

pub fn setCursorRow(self: *Window, row: u16) !void {
    if (self.terminal.modes.origin == 1) {
        // TODO
        log.err("setCursorRow: implement origin mode", .{});
        unreachable;
    }

    self.terminal.setCursorPos(row, self.terminal.screen.cursor.x + 1);
}

pub fn setCursorPos(self: *Window, row: u16, col: u16) !void {
    self.terminal.setCursorPos(row, col);
}

pub fn eraseDisplay(self: *Window, mode: terminal.EraseDisplay) !void {
    self.terminal.eraseDisplay(mode);
}

pub fn eraseLine(self: *Window, mode: terminal.EraseLine) !void {
    self.terminal.eraseLine(mode);
}

pub fn deleteChars(self: *Window, count: usize) !void {
    try self.terminal.deleteChars(count);
}

pub fn eraseChars(self: *Window, count: usize) !void {
    self.terminal.eraseChars(count);
}

pub fn insertLines(self: *Window, count: usize) !void {
    self.terminal.insertLines(count);
}

pub fn insertBlanks(self: *Window, count: usize) !void {
    self.terminal.insertBlanks(count);
}

pub fn deleteLines(self: *Window, count: usize) !void {
    self.terminal.deleteLines(count);
}

pub fn reverseIndex(self: *Window) !void {
    try self.terminal.reverseIndex();
}

pub fn index(self: *Window) !void {
    self.terminal.index();
}

pub fn nextLine(self: *Window) !void {
    self.terminal.carriageReturn();
    self.terminal.index();
}

pub fn setTopAndBottomMargin(self: *Window, top: u16, bot: u16) !void {
    self.terminal.setScrollingRegion(top, bot);
}

pub fn setMode(self: *Window, mode: terminal.Mode, enabled: bool) !void {
    switch (mode) {
        .reverse_colors => {
            self.terminal.modes.reverse_colors = @boolToInt(enabled);

            // Schedule a render since we changed colors
            try self.render_timer.schedule();
        },

        .origin => {
            self.terminal.modes.origin = @boolToInt(enabled);
            self.terminal.setCursorPos(1, 1);
        },

        .autowrap => {
            self.terminal.modes.autowrap = @boolToInt(enabled);
        },

        .alt_screen_save_cursor_clear_enter => {
            const opts: terminal.Terminal.AlternateScreenOptions = .{
                .cursor_save = true,
                .clear_on_enter = true,
            };

            if (enabled)
                self.terminal.alternateScreen(opts)
            else
                self.terminal.primaryScreen(opts);

            // Schedule a render since we changed screens
            try self.render_timer.schedule();
        },

        .bracketed_paste => self.bracketed_paste = true,

        .enable_mode_3 => {
            // Disable deccolm
            self.terminal.setDeccolmSupported(enabled);

            // Force resize back to the window size
            self.terminal.resize(self.alloc, self.grid.size.columns, self.grid.size.rows) catch |err|
                log.err("error updating terminal size: {}", .{err});
        },

        .@"132_column" => try self.terminal.deccolm(
            self.alloc,
            if (enabled) .@"132_cols" else .@"80_cols",
        ),

        else => if (enabled) log.warn("unimplemented mode: {}", .{mode}),
    }
}

pub fn setAttribute(self: *Window, attr: terminal.Attribute) !void {
    switch (attr) {
        .unknown => |unk| log.warn("unimplemented or unknown attribute: {any}", .{unk}),

        else => self.terminal.setAttribute(attr) catch |err|
            log.warn("error setting attribute {}: {}", .{ attr, err }),
    }
}

pub fn deviceAttributes(
    self: *Window,
    req: terminal.DeviceAttributeReq,
    params: []const u16,
) !void {
    _ = params;

    switch (req) {
        .primary => self.queueWrite("\x1B[?6c") catch |err|
            log.warn("error queueing device attr response: {}", .{err}),
        else => log.warn("unimplemented device attributes req: {}", .{req}),
    }
}

pub fn deviceStatusReport(
    self: *Window,
    req: terminal.DeviceStatusReq,
) !void {
    switch (req) {
        .operating_status => self.queueWrite("\x1B[0n") catch |err|
            log.warn("error queueing device attr response: {}", .{err}),

        .cursor_position => {
            const pos: struct {
                x: usize,
                y: usize,
            } = if (self.terminal.modes.origin == 1) .{
                // TODO: what do we do if cursor is outside scrolling region?
                .x = self.terminal.screen.cursor.x,
                .y = self.terminal.screen.cursor.y -| self.terminal.scrolling_region.top,
            } else .{
                .x = self.terminal.screen.cursor.x,
                .y = self.terminal.screen.cursor.y,
            };

            // Response always is at least 4 chars, so this leaves the
            // remainder for the row/column as base-10 numbers. This
            // will support a very large terminal.
            var buf: [32]u8 = undefined;
            const resp = try std.fmt.bufPrint(&buf, "\x1B[{};{}R", .{
                pos.y + 1,
                pos.x + 1,
            });

            try self.queueWrite(resp);
        },

        else => log.warn("unimplemented device status req: {}", .{req}),
    }
}

pub fn setCursorStyle(
    self: *Window,
    style: terminal.CursorStyle,
) !void {
    // Get the style that we use in the renderer
    const grid_style = Grid.CursorStyle.fromTerminal(style) orelse {
        log.warn("unimplemented cursor style: {}", .{style});
        return;
    };

    // Set our style
    self.cursor_style = style;

    // If we're currently focused, we update our style, since our unfocused
    // cursor is manually managed. If we're not focused, we ignore it because
    // it'll be updated the next time the window comes into focus.
    if (self.focused) try self.updateCursorStyle(grid_style, style.blinking());
}

pub fn decaln(self: *Window) !void {
    self.terminal.decaln();
}

pub fn tabClear(self: *Window, cmd: terminal.TabClear) !void {
    self.terminal.tabClear(cmd);
}

pub fn tabSet(self: *Window) !void {
    self.terminal.tabSet();
}

pub fn saveCursor(self: *Window) !void {
    self.terminal.saveCursor();
}

pub fn restoreCursor(self: *Window) !void {
    self.terminal.restoreCursor();
}

pub fn enquiry(self: *Window) !void {
    try self.queueWrite("");
}

pub fn setActiveStatusDisplay(
    self: *Window,
    req: terminal.StatusDisplay,
) !void {
    self.terminal.status_display = req;
}
