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
const libuv = @import("libuv");
const Pty = @import("Pty.zig");
const Command = @import("Command.zig");
const SegmentedPool = @import("segmented_pool.zig").SegmentedPool;
const trace = @import("tracy").trace;
const max_timer = @import("max_timer.zig");
const terminal = @import("terminal/main.zig");
const Config = @import("config.zig").Config;
const input = @import("input.zig");

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

/// Mouse state.
mouse: Mouse,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid. This is connected back to
/// a renderer.
terminal: terminal.Terminal,

/// The stream parser.
terminal_stream: terminal.Stream(*Window),

/// Cursor state.
terminal_cursor: Cursor,

/// Render at least 60fps.
render_timer: RenderTimer,

/// The reader/writer stream for the pty.
pty_stream: libuv.Tty,

/// This is the pool of available (unused) write requests. If you grab
/// one from the pool, you must put it back when you're done!
write_req_pool: SegmentedPool(libuv.WriteReq.T, WRITE_REQ_PREALLOC) = .{},

/// The pool of available buffers for writing to the pty.
write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

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

/// Information related to the current cursor for the window.
//
// QUESTION(mitchellh): should this be attached to the Screen instead?
// I'm not sure if the cursor settings stick to the screen, i.e. if you
// change to an alternate screen if those are preserved. Need to check this.
const Cursor = struct {
    /// Timer for cursor blinking.
    timer: libuv.Timer,

    /// Current cursor style. This can be set by escape sequences. To get
    /// the default style, the config has to be referenced.
    style: terminal.CursorStyle = .default,

    /// Whether the cursor is visible at all. This should not be used for
    /// "blink" settings, see "blink" for that. This is used to turn the
    /// cursor ON or OFF.
    visible: bool = true,

    /// Whether the cursor is currently blinking. If it is blinking, then
    /// the cursor will not be rendered.
    blink: bool = false,

    /// Start (or restart) the timer. This is idempotent.
    pub fn startTimer(self: Cursor) !void {
        try self.timer.start(
            cursorTimerCallback,
            0,
            self.timer.getRepeat(),
        );
    }

    /// Stop the timer. This is idempotent.
    pub fn stopTimer(self: Cursor) !void {
        try self.timer.stop();
    }
};

/// Mouse state for the window.
const Mouse = struct {
    /// The current state of mouse click.
    click_state: ClickState = .none,

    /// The point at which the mouse click happened. This is in screen
    /// coordinates so that scrolling preserves the location.
    click_point: terminal.point.ScreenPoint = .{},

    /// The starting xpos/ypos of the click. This is only useful initially.
    /// As soon as scrolling occurs, these are no longer accurate to calculate
    /// the screen point.
    click_xpos: f64 = 0,
    click_ypos: f64 = 0,

    const ClickState = enum { none, left };
};

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
        .cocoa_retina_framebuffer = true,
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
    if (builtin.mode == .Debug) {
        var ext_iter = try gl.ext.iterator();
        while (try ext_iter.next()) |ext| {
            log.debug("OpenGL extension available name={s}", .{ext});
        }
    }

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

    // Set a minimum size that is cols=10 h=4. This matches Mac's Terminal.app
    // but is otherwise somewhat arbitrary.
    try window.setSizeLimits(.{
        .width = @floatToInt(u32, grid.cell_size.width * 10),
        .height = @floatToInt(u32, grid.cell_size.height * 4),
    }, .{ .width = null, .height = null });

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
        .mouse = .{},
        .terminal = term,
        .terminal_stream = .{ .handler = self },
        .terminal_cursor = .{
            .timer = timer,
            .style = .blinking_block,
        },
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
    window.setCursorPosCallback(cursorPosCallback);
    window.setMouseButtonCallback(mouseButtonCallback);

    // Call our size callback which handles all our retina setup
    // Note: this shouldn't be necessary and when we clean up the window
    // init stuff we should get rid of this. But this is required because
    // sizeCallback does retina-aware stuff we don't do here and don't want
    // to duplicate.
    sizeCallback(
        window,
        @intCast(i32, window_size.width),
        @intCast(i32, window_size.height),
    );

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

    self.terminal_cursor.timer.close((struct {
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

        i = end;
    }
}

fn sizeCallback(window: glfw.Window, width: i32, height: i32) void {
    const tracy = trace(@src());
    defer tracy.end();

    // glfw gives us signed integers, but negative width/height is n
    // non-sensical so we use unsigned throughout, so assert.
    assert(width >= 0);
    assert(height >= 0);

    // Get our framebuffer size since this will give us the size in pixels
    // whereas width/height in this callback is in screen coordinates. For
    // Retina displays (or any other displays that have a scale factor),
    // these will not match.
    const px_size = window.getFramebufferSize() catch |err| err: {
        log.err("error querying window size in pixels, will use screen size err={}", .{err});
        break :err glfw.Window.Size{
            .width = @intCast(u32, width),
            .height = @intCast(u32, height),
        };
    };

    // Update our grid so that the projections on render are correct.
    const win = window.getUserPointer(Window) orelse return;
    win.grid.setScreenSize(.{
        .width = px_size.width,
        .height = px_size.height,
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

    // Update our viewport for this context to be the entire window.
    // OpenGL works in pixels, so we have to use the pixel size.
    gl.viewport(0, 0, @intCast(i32, px_size.width), @intCast(i32, px_size.height)) catch |err|
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

    // Anytime is character is created, we have to clear the selection
    if (win.terminal.selection != null) {
        win.terminal.selection = null;
        win.render_timer.schedule() catch |err|
            log.err("error scheduling render in charCallback err={}", .{err});
    }

    // We want to scroll to the bottom
    // TODO: detect if we're at the bottom to avoid the render call here.
    win.terminal.scrollViewport(.{ .bottom = {} });
    win.render_timer.schedule() catch |err|
        log.err("error scheduling render in charCallback err={}", .{err});

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

    const win = window.getUserPointer(Window) orelse return;

    // Reset the ignore char setting. If we didn't handle the char
    // by here, we aren't going to get it so we just reset this.
    win.ignore_char = false;

    //log.info("KEY {} {} {} {}", .{ key, scancode, mods, action });
    _ = scancode;

    if (action == .press or action == .repeat) {
        // Convert our glfw input into a platform agnostic trigger. When we
        // extract the platform out of this file, we'll pull a lot of this out
        // into a function. For now, this is the only place we do it so we just
        // put it right here.
        const trigger: input.Binding.Trigger = .{
            .mods = @bitCast(input.Mods, mods),
            .key = switch (key) {
                .a => .a,
                .b => .b,
                .c => .c,
                .d => .d,
                .e => .e,
                .f => .f,
                .g => .g,
                .h => .h,
                .i => .i,
                .j => .j,
                .k => .k,
                .l => .l,
                .m => .m,
                .n => .n,
                .o => .o,
                .p => .p,
                .q => .q,
                .r => .r,
                .s => .s,
                .t => .t,
                .u => .u,
                .v => .v,
                .w => .w,
                .x => .x,
                .y => .y,
                .z => .z,
                else => .invalid,
            },
        };

        if (win.config.keybind.set.get(trigger)) |binding_action| {
            log.warn("BINDING ACTION={}", .{binding_action});
            _ = binding_action;

            // Bindings always result in us ignoring the char if printable
            win.ignore_char = true;

            // No matter what, if there is a binding then we are done.
            return;
        }

        // Handle non-printables
        const char: u8 = switch (@bitCast(u8, mods)) {
            // No modifiers pressed at all
            0 => @as(u8, switch (key) {
                .backspace => 0x7F,
                .enter => '\r',
                .tab => '\t',
                .escape => 0x1B,
                else => 0,
            }),

            // Control only
            @bitCast(u8, glfw.Mods{ .control = true }) => @as(u8, switch (key) {
                .a => 0x01,
                .b => 0x02,
                .c => 0x03,
                .d => 0x04,
                .e => 0x05,
                .f => 0x06,
                .g => 0x07,
                .h => 0x08,
                .i => 0x09,
                .j => 0x0A,
                .k => 0x0B,
                .l => 0x0C,
                .m => 0x0D,
                .n => 0x0E,
                .o => 0x0F,
                .p => 0x10,
                .q => 0x11,
                .r => 0x12,
                .s => 0x13,
                .t => 0x14,
                .u => 0x15,
                .v => 0x16,
                .w => 0x17,
                .x => 0x18,
                .y => 0x19,
                .z => 0x1A,
                else => 0,
            }),

            else => 0,
        };
        if (char > 0) {
            win.queueWrite(&[1]u8{char}) catch |err|
                log.err("error queueing write in keyCallback err={}", .{err});
        }
    }

    if (action == .press and mods.super) {
        switch (key) {
            // Copy
            .c => {
                // Ignore this character for writing
                win.ignore_char = true;

                // If we have a selection, copy it.
                if (win.terminal.selection) |sel| {
                    var buf = win.terminal.screen.selectionString(win.alloc, sel) catch |err| {
                        log.err("error reading selection string err={}", .{err});
                        return;
                    };
                    defer win.alloc.free(buf);

                    glfw.setClipboardString(buf) catch |err| {
                        log.err("error setting clipboard string err={}", .{err});
                        return;
                    };
                }

                return;
            },

            // Paste
            .v => {

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
            },

            else => {},
        }
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
    // the cursor. If we're focused its reappearing, if we're not then
    // its changing to hollow and not blinking.
    win.render_timer.schedule() catch unreachable;

    // Set our focused state on the window.
    win.focused = focused;

    if (focused)
        win.terminal_cursor.startTimer() catch unreachable
    else
        win.terminal_cursor.stopTimer() catch unreachable;
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

fn mouseButtonCallback(
    window: glfw.Window,
    button: glfw.MouseButton,
    action: glfw.Action,
    mods: glfw.Mods,
) void {
    _ = mods;

    const tracy = trace(@src());
    defer tracy.end();

    if (button == .left) {
        switch (action) {
            .press => {
                const win = window.getUserPointer(Window) orelse return;
                const pos = window.getCursorPos() catch |err| {
                    log.err("error reading cursor position: {}", .{err});
                    return;
                };

                // Store it
                const point = win.posToViewport(pos.xpos, pos.ypos);
                win.mouse.click_state = .left;
                win.mouse.click_point = point.toScreen(&win.terminal.screen);
                win.mouse.click_xpos = pos.xpos;
                win.mouse.click_ypos = pos.ypos;
                log.debug("click start state={} viewport={} screen={}", .{
                    win.mouse.click_state,
                    point,
                    win.mouse.click_point,
                });

                // Selection is always cleared
                if (win.terminal.selection != null) {
                    win.terminal.selection = null;
                    win.render_timer.schedule() catch |err|
                        log.err("error scheduling render in mouseButtinCallback err={}", .{err});
                }
            },

            .release => {
                const win = window.getUserPointer(Window) orelse return;
                win.mouse.click_state = .none;
                log.debug("click end", .{});
            },

            .repeat => {},
        }
    }
}

fn cursorPosCallback(
    window: glfw.Window,
    xpos: f64,
    ypos: f64,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // If the cursor isn't clicked currently, it doesn't matter
    if (win.mouse.click_state != .left) return;

    // All roads lead to requiring a re-render at this pont.
    win.render_timer.schedule() catch |err|
        log.err("error scheduling render timer in cursorPosCallback err={}", .{err});

    // Convert to points
    const viewport_point = win.posToViewport(xpos, ypos);
    const screen_point = viewport_point.toScreen(&win.terminal.screen);

    // NOTE(mitchellh): This logic super sucks. There has to be an easier way
    // to calculate this, but this is good for a v1. Selection isn't THAT
    // common so its not like this performance heavy code is running that
    // often.
    // TODO: unit test this, this logic sucks

    // If we were selecting, and we switched directions, then we restart
    // calculations because it forces us to reconsider if the first cell is
    // selected.
    if (win.terminal.selection) |sel| {
        const reset: bool = if (sel.end.before(sel.start))
            sel.start.before(screen_point)
        else
            screen_point.before(sel.start);

        if (reset) win.terminal.selection = null;
    }

    // Our logic for determing if the starting cell is selected:
    //
    //   - The "xboundary" is 60% the width of a cell from the left. We choose
    //     60% somewhat arbitrarily based on feeling.
    //   - If we started our click left of xboundary, backwards selections
    //     can NEVER select the current char.
    //   - If we started our click right of xboundary, backwards selections
    //     ALWAYS selected the current char, but we must move the cursor
    //     left of the xboundary.
    //   - Inverted logic for forwards selections.
    //

    // the boundary point at which we consider selection or non-selection
    const cell_xboundary = win.grid.cell_size.width * 0.6;

    // first xpos of the clicked cell
    const cell_xstart = @intToFloat(f32, win.mouse.click_point.x) * win.grid.cell_size.width;
    const cell_start_xpos = win.mouse.click_xpos - cell_xstart;

    // If this is the same cell, then we only start the selection if weve
    // moved past the boundary point the opposite direction from where we
    // started.
    if (std.meta.eql(screen_point, win.mouse.click_point)) {
        const cell_xpos = xpos - cell_xstart;
        const selected: bool = if (cell_start_xpos < cell_xboundary)
            cell_xpos >= cell_xboundary
        else
            cell_xpos < cell_xboundary;

        win.terminal.selection = if (selected) .{
            .start = screen_point,
            .end = screen_point,
        } else null;

        return;
    }

    // If this is a different cell and we haven't started selection,
    // we determine the starting cell first.
    if (win.terminal.selection == null) {
        //   - If we're moving to a point before the start, then we select
        //     the starting cell if we started after the boundary, else
        //     we start selection of the prior cell.
        //   - Inverse logic for a point after the start.
        const click_point = win.mouse.click_point;
        const start: terminal.point.ScreenPoint = if (screen_point.before(click_point)) start: {
            if (win.mouse.click_xpos > cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x > 0) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x - 1,
                } else terminal.point.ScreenPoint{
                    .x = win.terminal.screen.cols - 1,
                    .y = click_point.y -| 1,
                };
            }
        } else start: {
            if (win.mouse.click_xpos < cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x < win.terminal.screen.cols - 1) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x + 1,
                } else terminal.point.ScreenPoint{
                    .y = click_point.y + 1,
                    .x = 0,
                };
            }
        };

        win.terminal.selection = .{ .start = start, .end = screen_point };
        return;
    }

    // TODO: detect if selection point is passed the point where we've
    // actually written data before and disallow it.

    // We moved! Set the selection end point. The start point should be
    // set earlier.
    assert(win.terminal.selection != null);
    win.terminal.selection.?.end = screen_point;
}

fn posToViewport(self: Window, xpos: f64, ypos: f64) terminal.point.Viewport {
    // xpos and ypos can be negative if while dragging, the user moves the
    // mouse off the window. Likewise, they can be larger than our window
    // width if the user drags out of the window positively.
    return .{
        .x = if (xpos < 0) 0 else x: {
            // Our cell is the mouse divided by cell width
            const cell_width = @floatCast(f64, self.grid.cell_size.width);
            const x = @floatToInt(usize, xpos / cell_width);

            // Can be off the screen if the user drags it out, so max
            // it out on our available columns
            break :x @minimum(x, self.terminal.cols - 1);
        },

        .y = if (ypos < 0) 0 else y: {
            const cell_height = @floatCast(f64, self.grid.cell_size.height);
            const y = @floatToInt(usize, ypos / cell_height);
            break :y @minimum(y, self.terminal.rows - 1);
        },
    };
}

fn cursorTimerCallback(t: *libuv.Timer) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = t.getData(Window) orelse return;

    // If the cursor is currently invisible, then we do nothing. Ideally
    // in this state the timer would be cancelled but no big deal.
    if (!win.terminal_cursor.visible) return;

    // Swap blink state and schedule a render
    win.terminal_cursor.blink = !win.terminal_cursor.blink;
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

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible.
    win.terminal_cursor.blink = false;
    if (win.terminal_cursor.timer.isActive() catch false) {
        _ = win.terminal_cursor.timer.again() catch null;
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

    // Setup our cursor settings
    if (win.focused) {
        win.grid.cursor_visible = win.terminal_cursor.visible and !win.terminal_cursor.blink;
        win.grid.cursor_style = Grid.CursorStyle.fromTerminal(win.terminal_cursor.style) orelse .box;
    } else {
        win.grid.cursor_visible = true;
        win.grid.cursor_style = .box_hollow;
    }

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

    // For now, rebuild all cells
    win.grid.rebuildCells(win.terminal) catch |err|
        log.err("error calling rebuildCells in render timer err={}", .{err});

    // Finalize the cells prior to render
    win.grid.finalizeCells(win.terminal) catch |err|
        log.err("error calling updateCells in render timer err={}", .{err});

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
    if (mode == .complete) {
        // Whenever we erase the full display, scroll to bottom.
        self.terminal.scrollViewport(.{ .bottom = {} });
        try self.render_timer.schedule();
    }

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

        .cursor_visible => {
            self.terminal_cursor.visible = enabled;
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
    self.terminal_cursor.style = style;
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
