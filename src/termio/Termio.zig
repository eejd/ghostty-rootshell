//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc. This is flexible enough to be used in environments
//! that don't have a pty and simply provides the input/output using raw
//! bytes.
pub const Termio = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.EnvMap;
const posix = std.posix;
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const Pty = @import("../pty.zig").Pty;
const SegmentedPool = @import("../segmented_pool.zig").SegmentedPool;
const terminal = @import("../terminal/main.zig");
const terminfo = @import("../terminfo/main.zig");
const xev = @import("xev");
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const shell_integration = @import("shell_integration.zig");

const StreamHandler = @import("stream_handler.zig").StreamHandler;

const log = std.log.scoped(.io_exec);

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

/// True if we should disable the kitty keyboard protocol. We have to
/// disable this on GLFW because GLFW input events don't support the
/// correct granularity of events.
const disable_kitty_keyboard_protocol = apprt.runtime == apprt.glfw;

/// Allocator
alloc: Allocator,

/// This is the pty fd created for the subcommand.
subprocess: Subprocess,

/// The derived configuration for this termio implementation.
config: DerivedConfig,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminal.Terminal,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// The cached grid size whenever a resize is called.
grid_size: renderer.GridSize,

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    palette: terminal.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminal.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.Color,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    term: []const u8,
    grapheme_width_method: configpkg.Config.GraphemeWidthMethod,
    abnormal_runtime_threshold_ms: u32,
    wait_after_command: bool,
    enquiry_response: []const u8,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        return .{
            .palette = config.palette.value,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .term = try alloc.dupe(u8, config.term),
            .grapheme_width_method = config.@"grapheme-width-method",
            .abnormal_runtime_threshold_ms = config.@"abnormal-command-exit-runtime",
            .wait_after_command = config.@"wait-after-command",
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),

            // This has to be last so that we copy AFTER the arena allocations
            // above happen (Zig assigns in order).
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Initialize the termio state.
///
/// This will also start the child process if the termio is configured
/// to run a child process.
pub fn init(alloc: Allocator, opts: termio.Options) !Termio {
    // Create our terminal
    var term = try terminal.Terminal.init(alloc, .{
        .cols = opts.grid_size.columns,
        .rows = opts.grid_size.rows,
        .max_scrollback = opts.full_config.@"scrollback-limit",
    });
    errdefer term.deinit(alloc);
    term.default_palette = opts.config.palette;
    term.color_palette.colors = opts.config.palette;

    // Setup our initial grapheme cluster support if enabled. We use a
    // switch to ensure we get a compiler error if more cases are added.
    switch (opts.config.grapheme_width_method) {
        .unicode => term.modes.set(.grapheme_cluster, true),
        .legacy => {},
    }

    // Set the image size limits
    try term.screen.kitty_images.setLimit(
        alloc,
        &term.screen,
        opts.config.image_storage_limit,
    );
    try term.secondary_screen.kitty_images.setLimit(
        alloc,
        &term.secondary_screen,
        opts.config.image_storage_limit,
    );

    // Set default cursor blink settings
    term.modes.set(
        .cursor_blinking,
        opts.config.cursor_blink orelse true,
    );

    // Set our default cursor style
    term.screen.cursor.cursor_style = opts.config.cursor_style;

    var subprocess = try Subprocess.init(alloc, opts);
    errdefer subprocess.deinit();

    // If we have an initial pwd requested by the subprocess, then we
    // set that on the terminal now. This allows rapidly initializing
    // new surfaces to use the proper pwd.
    if (subprocess.cwd) |cwd| term.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };

    // Initial width/height based on subprocess
    term.width_px = subprocess.screen_size.width;
    term.height_px = subprocess.screen_size.height;

    return .{
        .alloc = alloc,
        .terminal = term,
        .subprocess = subprocess,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .grid_size = opts.grid_size,
    };
}

pub fn deinit(self: *Termio) void {
    self.subprocess.deinit();
    self.terminal.deinit(self.alloc);
    self.config.deinit();
}

pub fn threadEnter(self: *Termio, thread: *termio.Thread, data: *ThreadData) !void {
    const alloc = self.alloc;

    // Start our subprocess
    const pty_fds = self.subprocess.start(alloc) catch |err| {
        // If we specifically got this error then we are in the forked
        // process and our child failed to execute. In that case
        if (err != error.Termio) return err;

        // Output an error message about the exec faililng and exit.
        // This generally should NOT happen because we always wrap
        // our command execution either in login (macOS) or /bin/sh
        // (Linux) which are usually guaranteed to exist. Still, we
        // want to handle this scenario.
        self.execFailedInChild() catch {};
        posix.exit(1);
    };
    errdefer self.subprocess.stop();
    const pid = pid: {
        const command = self.subprocess.command orelse return error.ProcessNotStarted;
        break :pid command.pid orelse return error.ProcessNoPid;
    };

    // Track our process start time so we know how long it was
    // running for.
    const process_start = try std.time.Instant.now();

    // Create our pipe that we'll use to kill our read thread.
    // pipe[0] is the read end, pipe[1] is the write end.
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    // Setup our data that is used for callbacks
    var ev_data_ptr = try alloc.create(EventData);
    errdefer alloc.destroy(ev_data_ptr);

    // Setup our stream so that we can write.
    var stream = xev.Stream.initFd(pty_fds.write);
    errdefer stream.deinit();

    // Wakeup watcher for the writer thread.
    var wakeup = try xev.Async.init();
    errdefer wakeup.deinit();

    // Watcher to detect subprocess exit
    var process = try xev.Process.init(pid);
    errdefer process.deinit();

    // Create our stream handler
    const handler: StreamHandler = handler: {
        const default_cursor_color = if (self.config.cursor_color) |col|
            col.toTerminalRGB()
        else
            null;

        break :handler .{
            .alloc = self.alloc,
            .writer_mailbox = thread.mailbox,
            .writer_wakeup = thread.wakeup,
            .surface_mailbox = self.surface_mailbox,
            .renderer_state = self.renderer_state,
            .renderer_wakeup = self.renderer_wakeup,
            .renderer_mailbox = self.renderer_mailbox,
            .grid_size = &self.grid_size,
            .terminal = &self.terminal,
            .osc_color_report_format = self.config.osc_color_report_format,
            .enquiry_response = self.config.enquiry_response,
            .default_foreground_color = self.config.foreground.toTerminalRGB(),
            .default_background_color = self.config.background.toTerminalRGB(),
            .default_cursor_style = self.config.cursor_style,
            .default_cursor_blink = self.config.cursor_blink,
            .default_cursor_color = default_cursor_color,
            .cursor_color = default_cursor_color,
            .foreground_color = self.config.foreground.toTerminalRGB(),
            .background_color = self.config.background.toTerminalRGB(),
        };
    };

    // Setup our event data before we start
    ev_data_ptr.* = .{
        .writer_mailbox = thread.mailbox,
        .writer_wakeup = thread.wakeup,
        .surface_mailbox = self.surface_mailbox,
        .renderer_state = self.renderer_state,
        .renderer_wakeup = self.renderer_wakeup,
        .renderer_mailbox = self.renderer_mailbox,
        .process = process,
        .data_stream = stream,
        .loop = &thread.loop,
        .terminal_stream = .{
            .handler = handler,
            .parser = .{
                .osc_parser = .{
                    // Populate the OSC parser allocator (optional) because
                    // we want to support large OSC payloads such as OSC 52.
                    .alloc = self.alloc,
                },
            },
        },
    };
    errdefer ev_data_ptr.deinit(self.alloc);

    // Start our process watcher
    process.wait(
        ev_data_ptr.loop,
        &ev_data_ptr.process_wait_c,
        ThreadData,
        data,
        processExit,
    );

    // Start our reader thread
    const read_thread = try std.Thread.spawn(
        .{},
        if (builtin.os.tag == .windows) ReadThread.threadMainWindows else ReadThread.threadMainPosix,
        .{ pty_fds.read, ev_data_ptr, pipe[0] },
    );
    read_thread.setName("io-reader") catch {};

    // Return our thread data
    data.* = .{
        .alloc = alloc,
        .ev = ev_data_ptr,
        .reader = .{ .exec = .{
            .start = process_start,
            .abnormal_runtime_threshold_ms = self.config.abnormal_runtime_threshold_ms,
            .wait_after_command = self.config.wait_after_command,
        } },
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = if (builtin.os.tag == .windows) pty_fds.read else {},
    };
}

/// This outputs an error message when exec failed and we are the
/// child process. This returns so the caller should probably exit
/// after calling this.
///
/// Note that this usually is only called under very very rare
/// circumstances because we wrap our command execution in login
/// (macOS) or /bin/sh (Linux). So this output can be pretty crude
/// because it should never happen. Notably, this is not the error
/// users see when `command` is invalid.
fn execFailedInChild(self: *Termio) !void {
    _ = self;
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll("exec failed\n");
    try stderr.writeAll("press any key to exit\n");

    var buf: [1]u8 = undefined;
    var reader = std.io.getStdIn().reader();
    _ = try reader.read(&buf);
}

pub fn threadExit(self: *Termio, data: *ThreadData) void {
    // Stop our reader
    switch (data.reader) {
        .manual => {},

        .exec => |exec| {
            if (exec.exited) self.subprocess.externalExit();
            self.subprocess.stop();

            // Quit our read thread after exiting the subprocess so that
            // we don't get stuck waiting for data to stop flowing if it is
            // a particularly noisy process.
            _ = posix.write(data.read_thread_pipe, "x") catch |err|
                log.warn("error writing to read thread quit pipe err={}", .{err});

            if (comptime builtin.os.tag == .windows) {
                // Interrupt the blocking read so the thread can see the quit message
                if (windows.kernel32.CancelIoEx(data.read_thread_fd, null) == 0) {
                    switch (windows.kernel32.GetLastError()) {
                        .NOT_FOUND => {},
                        else => |err| log.warn("error interrupting read thread err={}", .{err}),
                    }
                }
            }

            data.read_thread.join();
        },
    }
}

/// Update the configuration.
pub fn changeConfig(self: *Termio, td: *ThreadData, config: *DerivedConfig) !void {
    // The remainder of this function is modifying terminal state or
    // the read thread data, all of which requires holding the renderer
    // state lock.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // Deinit our old config. We do this in the lock because the
    // stream handler may be referencing the old config (i.e. enquiry resp)
    self.config.deinit();
    self.config = config.*;

    // Update our stream handler. The stream handler uses the same
    // renderer mutex so this is safe to do despite being executed
    // from another thread.
    td.ev.terminal_stream.handler.changeConfig(&self.config);
    td.reader.changeConfig(&self.config);

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the default palette. Note this will only apply to new colors drawn
    // since we decode all palette colors to RGB on usage.
    self.terminal.default_palette = config.palette;

    // Update the active palette, except for any colors that were modified with
    // OSC 4
    for (0..config.palette.len) |i| {
        if (!self.terminal.color_palette.mask.isSet(i)) {
            self.terminal.color_palette.colors[i] = config.palette[i];
            self.terminal.flags.dirty.palette = true;
        }
    }

    // Set the image size limits
    try self.terminal.screen.kitty_images.setLimit(
        self.alloc,
        &self.terminal.screen,
        config.image_storage_limit,
    );
    try self.terminal.secondary_screen.kitty_images.setLimit(
        self.alloc,
        &self.terminal.secondary_screen,
        config.image_storage_limit,
    );
}

/// Resize the terminal.
pub fn resize(
    self: *Termio,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    padding: renderer.Padding,
) !void {
    // Update the size of our pty.
    const padded_size = screen_size.subPadding(padding);
    try self.subprocess.resize(grid_size, padded_size);

    // Update our cached grid size
    self.grid_size = grid_size;

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // Update the size of our terminal state
        try self.terminal.resize(
            self.alloc,
            grid_size.columns,
            grid_size.rows,
        );

        // Update our pixel sizes
        self.terminal.width_px = padded_size.width;
        self.terminal.height_px = padded_size.height;

        // Disable synchronized output mode so that we show changes
        // immediately for a resize. This is allowed by the spec.
        self.terminal.modes.set(.synchronized_output, false);

        // Wake up our renderer so any changes will be shown asap
        self.renderer_wakeup.notify() catch {};
    }
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
}

/// Clear the screen.
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.active_screen == .alternate) return;

        // Clear our scrollback
        if (history) self.terminal.eraseDisplay(.scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            if (self.terminal.screen.cursor.y > 0) {
                self.terminal.screen.eraseRows(
                    .{ .active = .{ .y = 0 } },
                    .{ .active = .{ .y = self.terminal.screen.cursor.y - 1 } },
                );
            }

            return;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        // Mark the current row as a not a prompt so we can properly
        // clear the full screen in the next eraseDisplay call.
        self.terminal.markSemanticPrompt(.command);
        assert(!self.terminal.cursorIsAtPrompt());
        self.terminal.eraseDisplay(.complete, false);
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(self: *Termio, scroll: terminal.Terminal.ScrollViewport) !void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    try self.terminal.scrollViewport(scroll);
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        self.terminal.screen.scroll(.{ .delta_prompt = delta });
    }

    try self.renderer_wakeup.notify();
}

/// Called when the child process exited abnormally but before
/// the surface is notified.
pub fn childExitedAbnormally(self: *Termio, exit_code: u32, runtime_ms: u64) !void {
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build up our command for the error message
    const command = try std.mem.join(alloc, " ", self.subprocess.args);
    const runtime_str = try std.fmt.allocPrint(alloc, "{d} ms", .{runtime_ms});

    // Modify the terminal to show our error message. This
    // requires grabbing the renderer state lock.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    const t = self.renderer_state.terminal;

    // No matter what move the cursor back to the column 0.
    t.carriageReturn();

    // Reset styles
    try t.setAttribute(.{ .unset = {} });

    // If there is data in the viewport, we want to scroll down
    // a little bit and write a horizontal rule before writing
    // our message. This lets the use see the error message the
    // command may have output.
    const viewport_str = try t.plainString(alloc);
    if (viewport_str.len > 0) {
        try t.linefeed();
        for (0..t.cols) |_| try t.print(0x2501);
        t.carriageReturn();
        try t.linefeed();
        try t.linefeed();
    }

    // Output our error message
    try t.setAttribute(.{ .@"8_fg" = .bright_red });
    try t.setAttribute(.{ .bold = {} });
    try t.printString("Ghostty failed to launch the requested command:");
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString(command);
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Runtime: ");
    try t.setAttribute(.{ .@"8_fg" = .red });
    try t.printString(runtime_str);
    try t.setAttribute(.{ .unset = {} });

    // We don't print this on macOS because the exit code is always 0
    // due to the way we launch the process.
    if (comptime !builtin.target.isDarwin()) {
        const exit_code_str = try std.fmt.allocPrint(alloc, "{d}", .{exit_code});
        t.carriageReturn();
        try t.linefeed();
        try t.printString("Exit Code: ");
        try t.setAttribute(.{ .@"8_fg" = .red });
        try t.printString(exit_code_str);
        try t.setAttribute(.{ .unset = {} });
    }

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Press any key to close the window.");

    // Hide the cursor
    t.modes.set(.cursor_visible, false);
}

pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    const ev = td.ev;

    // If our process is exited then we send our surface a message
    // about it but we don't queue any more writes.
    switch (td.reader) {
        .manual => {},
        .exec => |exec| {
            if (exec.exited) {
                _ = ev.surface_mailbox.push(.{
                    .child_exited = {},
                }, .{ .forever = {} });
                return;
            }
        },
    }

    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const req = try ev.write_req_pool.getGrow(self.alloc);
        const buf = try ev.write_buf_pool.getGrow(self.alloc);
        const slice = slice: {
            // The maximum end index is either the end of our data or
            // the end of our buffer, whichever is smaller.
            const max = @min(data.len, i + buf.len);

            // Fast
            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }

            // Slow, have to replace \r with \r\n
            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;

                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }

                // CRLF
                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }

            break :slice buf[0..buf_i];
        };

        //for (slice) |b| log.warn("write: {x}", .{b});

        ev.data_stream.queueWrite(
            ev.loop,
            &ev.write_queue,
            req,
            .{ .slice = slice },
            EventData,
            ev,
            ttyWrite,
        );
    }
}

fn readInternal(
    ev: *EventData,
    buf: []const u8,
) void {
    // log.info("DATA: {d}", .{n});
    // log.info("DATA: {any}", .{buf[0..@intCast(usize, n)]});

    // We are modifying terminal state from here on out
    ev.renderer_state.mutex.lock();
    defer ev.renderer_state.mutex.unlock();

    // Schedule a render. We can call this first because we have the lock.
    ev.queueRender() catch unreachable;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    const now = ev.loop.now();
    if (now - ev.last_cursor_reset > 500) {
        ev.last_cursor_reset = now;
        _ = ev.renderer_mailbox.push(.{
            .reset_cursor_blink = {},
        }, .{ .forever = {} });
    }

    // If we have an inspector, we enter SLOW MODE because we need to
    // process a byte at a time alternating between the inspector handler
    // and the termio handler. This is very slow compared to our optimizations
    // below but at least users only pay for it if they're using the inspector.
    if (ev.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(buf[i .. i + 1]) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };

            ev.terminal_stream.next(byte) catch |err|
                log.err("error processing terminal data: {}", .{err});
        }
    } else {
        ev.terminal_stream.nextSlice(buf) catch |err|
            log.err("error processing terminal data: {}", .{err});
    }

    // If our stream handling caused messages to be sent to the writer
    // thread, then we need to wake it up so that it processes them.
    if (ev.terminal_stream.handler.writer_messaged) {
        ev.terminal_stream.handler.writer_messaged = false;
        ev.writer_wakeup.notify() catch |err| {
            log.warn("failed to wake up writer thread err={}", .{err});
        };
    }
}

/// ThreadData is the data created and stored in the termio thread
/// when the thread is started and destroyed when the thread is
/// stopped.
///
/// All of the fields in this struct should only be read/written by
/// the termio thread. As such, a lock is not necessary.
pub const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The data that is attached to the callbacks.
    ev: *EventData,

    /// Data associated with the reader implementation (i.e. pty/exec state)
    reader: termio.reader.ThreadData,

    /// Our read thread
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    read_thread_fd: if (builtin.os.tag == .windows) posix.fd_t else void,

    pub fn deinit(self: *ThreadData) void {
        posix.close(self.read_thread_pipe);
        self.ev.deinit(self.alloc);
        self.alloc.destroy(self.ev);
        self.* = undefined;
    }
};

pub const EventData = struct {
    // The preallocation size for the write request pool. This should be big
    // enough to satisfy most write requests. It must be a power of 2.
    const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

    /// Mailbox for data to the writer thread.
    writer_mailbox: *termio.Mailbox,
    writer_wakeup: xev.Async,

    /// Mailbox for the surface.
    surface_mailbox: apprt.surface.Mailbox,

    /// The stream parser. This parses the stream of escape codes and so on
    /// from the child process and calls callbacks in the stream handler.
    terminal_stream: terminal.Stream(StreamHandler),

    /// The shared render state
    renderer_state: *renderer.State,

    /// A handle to wake up the renderer. This hints to the renderer that that
    /// a repaint should happen.
    renderer_wakeup: xev.Async,

    /// The mailbox for notifying the renderer of things.
    renderer_mailbox: *renderer.Thread.Mailbox,

    /// The process watcher
    process: xev.Process,

    /// This is used for both waiting for the process to exit and then
    /// subsequently to wait for the data_stream to close.
    process_wait_c: xev.Completion = .{},

    /// The data stream is the main IO for the pty.
    data_stream: xev.Stream,

    /// The event loop,
    loop: *xev.Loop,

    /// The write queue for the data stream.
    write_queue: xev.Stream.WriteQueue = .{},

    /// This is the pool of available (unused) write requests. If you grab
    /// one from the pool, you must put it back when you're done!
    write_req_pool: SegmentedPool(xev.Stream.WriteRequest, WRITE_REQ_PREALLOC) = .{},

    /// The pool of available buffers for writing to the pty.
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

    /// Last time the cursor was reset. This is used to prevent message
    /// flooding with cursor resets.
    last_cursor_reset: i64 = 0,

    pub fn deinit(self: *EventData, alloc: Allocator) void {
        // Clear our write pools. We know we aren't ever going to do
        // any more IO since we stop our data stream below so we can just
        // drop this.
        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);

        // Stop our data stream
        self.data_stream.deinit();

        // Stop our process watcher
        self.process.deinit();

        // Clear any StreamHandler state
        self.terminal_stream.handler.deinit();
        self.terminal_stream.deinit();
    }

    /// This queues a render operation with the renderer thread. The render
    /// isn't guaranteed to happen immediately but it will happen as soon as
    /// practical.
    pub inline fn queueRender(self: *EventData) !void {
        try self.renderer_wakeup.notify();
    }
};

fn processExit(
    td_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const exit_code = r catch unreachable;

    const td = td_.?;
    assert(td.reader == .exec);
    const ev = td.ev;
    const execdata = &td.reader.exec;
    execdata.exited = true;

    // Determine how long the process was running for.
    const runtime_ms: ?u64 = runtime: {
        const process_end = std.time.Instant.now() catch break :runtime null;
        const runtime_ns = process_end.since(execdata.start);
        const runtime_ms = runtime_ns / std.time.ns_per_ms;
        break :runtime runtime_ms;
    };
    log.debug(
        "child process exited status={} runtime={}ms",
        .{ exit_code, runtime_ms orelse 0 },
    );

    // If our runtime was below some threshold then we assume that this
    // was an abnormal exit and we show an error message.
    if (runtime_ms) |runtime| runtime: {
        // On macOS, our exit code detection doesn't work, possibly
        // because of our `login` wrapper. More investigation required.
        if (comptime !builtin.target.isDarwin()) {
            // If our exit code is zero, then the command was successful
            // and we don't ever consider it abnormal.
            if (exit_code == 0) break :runtime;
        }

        // Our runtime always has to be under the threshold to be
        // considered abnormal. This is because a user can always
        // manually do something like `exit 1` in their shell to
        // force the exit code to be non-zero. We only want to detect
        // abnormal exits that happen so quickly the user can't react.
        if (runtime > execdata.abnormal_runtime_threshold_ms) break :runtime;
        log.warn("abnormal process exit detected, showing error message", .{});

        // Notify our main writer thread which has access to more
        // information so it can show a better error message.
        _ = ev.writer_mailbox.push(.{
            .child_exited_abnormally = .{
                .exit_code = exit_code,
                .runtime_ms = runtime,
            },
        }, .{ .forever = {} });
        ev.writer_wakeup.notify() catch break :runtime;

        return .disarm;
    }

    // If we're purposely waiting then we just return since the process
    // exited flag is set to true. This allows the terminal window to remain
    // open.
    if (execdata.wait_after_command) {
        // We output a message so that the user knows whats going on and
        // doesn't think their terminal just froze.
        terminal: {
            ev.renderer_state.mutex.lock();
            defer ev.renderer_state.mutex.unlock();
            const t = ev.renderer_state.terminal;
            t.carriageReturn();
            t.linefeed() catch break :terminal;
            t.printString("Process exited. Press any key to close the terminal.") catch
                break :terminal;
            t.modes.set(.cursor_visible, false);
        }

        return .disarm;
    }

    // Notify our surface we want to close
    _ = ev.surface_mailbox.push(.{
        .child_exited = {},
    }, .{ .forever = {} });

    return .disarm;
}

fn ttyWrite(
    ev_: ?*EventData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.Stream.WriteError!usize,
) xev.CallbackAction {
    const ev = ev_.?;
    ev.write_req_pool.put();
    ev.write_buf_pool.put();

    const d = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };
    _ = d;
    //log.info("WROTE: {d}", .{d});

    return .disarm;
}

/// Subprocess manages the lifecycle of the shell subprocess.
const Subprocess = struct {
    /// If we build with flatpak support then we have to keep track of
    /// a potential execution on the host.
    const FlatpakHostCommand = if (build_config.flatpak) internal_os.FlatpakHostCommand else void;

    arena: std.heap.ArenaAllocator,
    cwd: ?[]const u8,
    env: EnvMap,
    args: [][]const u8,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    pty: ?Pty = null,
    command: ?Command = null,
    flatpak_command: ?FlatpakHostCommand = null,
    linux_cgroup: Command.LinuxCgroup = Command.linux_cgroup_default,

    /// Initialize the subprocess. This will NOT start it, this only sets
    /// up the internal state necessary to start it later.
    pub fn init(gpa: Allocator, opts: termio.Options) !Subprocess {
        // We have a lot of maybe-allocations that all share the same lifetime
        // so use an arena so we don't end up in an accounting nightmare.
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Set our env vars. For Flatpak builds running in Flatpak we don't
        // inherit our environment because the login shell on the host side
        // will get it.
        var env = env: {
            if (comptime build_config.flatpak) {
                if (internal_os.isFlatpak()) {
                    break :env std.process.EnvMap.init(alloc);
                }
            }

            break :env try std.process.getEnvMap(alloc);
        };
        errdefer env.deinit();

        // If we have a resources dir then set our env var
        if (opts.resources_dir) |dir| {
            log.info("found Ghostty resources dir: {s}", .{dir});
            try env.put("GHOSTTY_RESOURCES_DIR", dir);
        }

        // Set our TERM var. This is a bit complicated because we want to use
        // the ghostty TERM value but we want to only do that if we have
        // ghostty in the TERMINFO database.
        //
        // For now, we just look up a bundled dir but in the future we should
        // also load the terminfo database and look for it.
        if (opts.resources_dir) |base| {
            try env.put("TERM", opts.config.term);
            try env.put("COLORTERM", "truecolor");

            // Assume that the resources directory is adjacent to the terminfo
            // database
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buf, "{s}/terminfo", .{
                std.fs.path.dirname(base) orelse unreachable,
            });
            try env.put("TERMINFO", dir);
        } else {
            if (comptime builtin.target.isDarwin()) {
                log.warn("ghostty terminfo not found, using xterm-256color", .{});
                log.warn("the terminfo SHOULD exist on macos, please ensure", .{});
                log.warn("you're using a valid app bundle.", .{});
            }

            try env.put("TERM", "xterm-256color");
            try env.put("COLORTERM", "truecolor");
        }

        // Add our binary to the path if we can find it.
        ghostty_path: {
            var exe_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const exe_bin_path = std.fs.selfExePath(&exe_buf) catch |err| {
                log.warn("failed to get ghostty exe path err={}", .{err});
                break :ghostty_path;
            };
            const exe_dir = std.fs.path.dirname(exe_bin_path) orelse break :ghostty_path;
            log.debug("appending ghostty bin to path dir={s}", .{exe_dir});

            // We always set this so that if the shell overwrites the path
            // scripts still have a way to find the Ghostty binary when
            // running in Ghostty.
            try env.put("GHOSTTY_BIN_DIR", exe_dir);

            // Append if we have a path. We want to append so that ghostty is
            // the last priority in the path. If we don't have a path set
            // then we just set it to the directory of the binary.
            if (env.get("PATH")) |path| {
                // Verify that our path doesn't already contain this entry
                var it = std.mem.tokenizeScalar(u8, path, internal_os.PATH_SEP[0]);
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry, exe_dir)) break :ghostty_path;
                }

                try env.put(
                    "PATH",
                    try internal_os.appendEnv(alloc, path, exe_dir),
                );
            } else {
                try env.put("PATH", exe_dir);
            }
        }

        // Add the man pages from our application bundle to MANPATH.
        if (comptime builtin.target.isDarwin()) {
            if (opts.resources_dir) |resources_dir| man: {
                var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const dir = std.fmt.bufPrint(&buf, "{s}/../man", .{resources_dir}) catch |err| {
                    log.warn("error building manpath, man pages may not be available err={}", .{err});
                    break :man;
                };

                if (env.get("MANPATH")) |manpath| {
                    // Append to the existing MANPATH. It's very unlikely that our bundle's
                    // resources directory already appears here so we don't spend the time
                    // searching for it.
                    try env.put(
                        "MANPATH",
                        try internal_os.appendEnv(alloc, manpath, dir),
                    );
                } else {
                    try env.put("MANPATH", dir);
                }
            }
        }

        // Set environment variables used by some programs (such as neovim) to detect
        // which terminal emulator and version they're running under.
        try env.put("TERM_PROGRAM", "ghostty");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);

        // When embedding in macOS and running via XCode, XCode injects
        // a bunch of things that break our shell process. We remove those.
        if (comptime builtin.target.isDarwin() and build_config.artifact == .lib) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                env.remove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                env.remove("__XPC_DYLD_LIBRARY_PATH");
                env.remove("DYLD_FRAMEWORK_PATH");
                env.remove("DYLD_INSERT_LIBRARIES");
                env.remove("DYLD_LIBRARY_PATH");
                env.remove("LD_LIBRARY_PATH");
                env.remove("SECURITYSESSIONID");
                env.remove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghostty` within Ghostty works.
            env.remove("GHOSTTY_MAC_APP");
        }

        // Don't leak these environment variables to child processes.
        if (comptime build_config.app_runtime == .gtk) {
            env.remove("GDK_DEBUG");
            env.remove("GSK_RENDERER");
        }

        // Setup our shell integration, if we can.
        const integrated_shell: ?shell_integration.Shell, const shell_command: []const u8 = shell: {
            const default_shell_command = opts.full_config.command orelse switch (builtin.os.tag) {
                .windows => "cmd.exe",
                else => "sh",
            };

            const force: ?shell_integration.Shell = switch (opts.full_config.@"shell-integration") {
                .none => break :shell .{ null, default_shell_command },
                .detect => null,
                .bash => .bash,
                .elvish => .elvish,
                .fish => .fish,
                .zsh => .zsh,
            };

            const dir = opts.resources_dir orelse break :shell .{
                null,
                default_shell_command,
            };

            const integration = try shell_integration.setup(
                alloc,
                dir,
                default_shell_command,
                &env,
                force,
                opts.full_config.@"shell-integration-features",
            ) orelse break :shell .{ null, default_shell_command };

            break :shell .{ integration.shell, integration.command };
        };

        if (integrated_shell) |shell| {
            log.info(
                "shell integration automatically injected shell={}",
                .{shell},
            );
        } else if (opts.full_config.@"shell-integration" != .none) {
            log.warn("shell could not be detected, no automatic shell integration will be injected", .{});
        }

        // Build our args list
        const args = args: {
            const cap = 9; // the most we'll ever use
            var args = try std.ArrayList([]const u8).initCapacity(alloc, cap);
            defer args.deinit();

            // If we're on macOS, we have to use `login(1)` to get all of
            // the proper environment variables set, a login shell, and proper
            // hushlogin behavior.
            if (comptime builtin.target.isDarwin()) darwin: {
                const passwd = internal_os.passwd.get(alloc) catch |err| {
                    log.warn("failed to read passwd, not using a login shell err={}", .{err});
                    break :darwin;
                };

                const username = passwd.name orelse {
                    log.warn("failed to get username, not using a login shell", .{});
                    break :darwin;
                };

                const hush = if (passwd.home) |home| hush: {
                    var dir = std.fs.openDirAbsolute(home, .{}) catch |err| {
                        log.warn(
                            "failed to open home dir, not checking for hushlogin err={}",
                            .{err},
                        );
                        break :hush false;
                    };
                    defer dir.close();

                    break :hush if (dir.access(".hushlogin", .{})) true else |_| false;
                } else false;

                const cmd = try std.fmt.allocPrint(
                    alloc,
                    "exec -l {s}",
                    .{shell_command},
                );

                // The reason for executing login this way is unclear. This
                // comment will attempt to explain but prepare for a truly
                // unhinged reality.
                //
                // The first major issue is that on macOS, a lot of users
                // put shell configurations in ~/.bash_profile instead of
                // ~/.bashrc (or equivalent for another shell). This file is only
                // loaded for a login shell so macOS users expect all their terminals
                // to be login shells. No other platform behaves this way and its
                // totally braindead but somehow the entire dev community on
                // macOS has cargo culted their way to this reality so we have to
                // do it...
                //
                // To get a login shell, you COULD just prepend argv0 with a `-`
                // but that doesn't fully work because `getlogin()` C API will
                // return the wrong value, SHELL won't be set, and various
                // other login behaviors that macOS users expect.
                //
                // The proper way is to use `login(1)`. But login(1) forces
                // the working directory to change to the home directory,
                // which we may not want. If we specify "-l" then we can avoid
                // this behavior but now the shell isn't a login shell.
                //
                // There is another issue: `login(1)` only checks for ".hushlogin"
                // in the working directory. This means that if we specify "-l"
                // then we won't get hushlogin honored if its in the home
                // directory (which is standard). To get around this, we
                // check for hushlogin ourselves and if present specify the
                // "-q" flag to login(1).
                //
                // So to get all the behaviors we want, we specify "-l" but
                // execute "bash" (which is built-in to macOS). We then use
                // the bash builtin "exec" to replace the process with a login
                // shell ("-l" on exec) with the command we really want.
                //
                // We use "bash" instead of other shells that ship with macOS
                // because as of macOS Sonoma, we found with a microbenchmark
                // that bash can `exec` into the desired command ~2x faster
                // than zsh.
                //
                // To figure out a lot of this logic I read the login.c
                // source code in the OSS distribution Apple provides for
                // macOS.
                //
                // Awesome.
                try args.append("/usr/bin/login");
                if (hush) try args.append("-q");
                try args.append("-flp");

                // We execute bash with "--noprofile --norc" so that it doesn't
                // load startup files so that (1) our shell integration doesn't
                // break and (2) user configuration doesn't mess this process
                // up.
                try args.append(username);
                try args.append("/bin/bash");
                try args.append("--noprofile");
                try args.append("--norc");
                try args.append("-c");
                try args.append(cmd);
                break :args try args.toOwnedSlice();
            }

            if (comptime builtin.os.tag == .windows) {
                // We run our shell wrapped in `cmd.exe` so that we don't have
                // to parse the command line ourselves if it has arguments.

                // Note we don't free any of the memory below since it is
                // allocated in the arena.
                const windir = try std.process.getEnvVarOwned(alloc, "WINDIR");
                const cmd = try std.fs.path.join(alloc, &[_][]const u8{
                    windir,
                    "System32",
                    "cmd.exe",
                });

                try args.append(cmd);
                try args.append("/C");
            } else {
                // We run our shell wrapped in `/bin/sh` so that we don't have
                // to parse the command line ourselves if it has arguments.
                // Additionally, some environments (NixOS, I found) use /bin/sh
                // to setup some environment variables that are important to
                // have set.
                try args.append("/bin/sh");
                if (internal_os.isFlatpak()) try args.append("-l");
                try args.append("-c");
            }

            try args.append(shell_command);
            break :args try args.toOwnedSlice();
        };

        // We have to copy the cwd because there is no guarantee that
        // pointers in full_config remain valid.
        const cwd: ?[]u8 = if (opts.full_config.@"working-directory") |cwd|
            try alloc.dupe(u8, cwd)
        else
            null;

        // If we have a cgroup, then we copy that into our arena so the
        // memory remains valid when we start.
        const linux_cgroup: Command.LinuxCgroup = cgroup: {
            const default = Command.linux_cgroup_default;
            if (comptime builtin.os.tag != .linux) break :cgroup default;
            const path = opts.linux_cgroup orelse break :cgroup default;
            break :cgroup try alloc.dupe(u8, path);
        };

        // Our screen size should be our padded size
        const padded_size = opts.screen_size.subPadding(opts.padding);

        return .{
            .arena = arena,
            .env = env,
            .cwd = cwd,
            .args = args,
            .grid_size = opts.grid_size,
            .screen_size = padded_size,
            .linux_cgroup = linux_cgroup,
        };
    }

    /// Clean up the subprocess. This will stop the subprocess if it is started.
    pub fn deinit(self: *Subprocess) void {
        self.stop();
        if (self.pty) |*pty| pty.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Start the subprocess. If the subprocess is already started this
    /// will crash.
    pub fn start(self: *Subprocess, alloc: Allocator) !struct {
        read: Pty.Fd,
        write: Pty.Fd,
    } {
        assert(self.pty == null and self.command == null);

        // Create our pty
        var pty = try Pty.open(.{
            .ws_row = @intCast(self.grid_size.rows),
            .ws_col = @intCast(self.grid_size.columns),
            .ws_xpixel = @intCast(self.screen_size.width),
            .ws_ypixel = @intCast(self.screen_size.height),
        });
        self.pty = pty;
        errdefer {
            pty.deinit();
            self.pty = null;
        }

        log.debug("starting command command={s}", .{self.args});

        // In flatpak, we use the HostCommand to execute our shell.
        if (internal_os.isFlatpak()) flatpak: {
            if (comptime !build_config.flatpak) {
                log.warn("flatpak detected, but flatpak support not built-in", .{});
                break :flatpak;
            }

            // Flatpak command must have a stable pointer.
            self.flatpak_command = .{
                .argv = self.args,
                .env = &self.env,
                .stdin = pty.slave,
                .stdout = pty.slave,
                .stderr = pty.slave,
            };
            var cmd = &self.flatpak_command.?;
            const pid = try cmd.spawn(alloc);
            errdefer killCommandFlatpak(cmd);

            log.info("started subcommand on host via flatpak API path={s} pid={?}", .{
                self.args[0],
                pid,
            });

            // Once started, we can close the pty child side. We do this after
            // wait right now but that is fine too. This lets us read the
            // parent and detect EOF.
            _ = posix.close(pty.slave);

            return .{
                .read = pty.master,
                .write = pty.master,
            };
        }

        // If we can't access the cwd, then don't set any cwd and inherit.
        // This is important because our cwd can be set by the shell (OSC 7)
        // and we don't want to break new windows.
        const cwd: ?[]const u8 = if (self.cwd) |proposed| cwd: {
            if (std.fs.accessAbsolute(proposed, .{})) {
                break :cwd proposed;
            } else |err| {
                log.warn("cannot access cwd, ignoring: {}", .{err});
                break :cwd null;
            }
        } else null;

        // Build our subcommand
        var cmd: Command = .{
            .path = self.args[0],
            .args = self.args,
            .env = &self.env,
            .cwd = cwd,
            .stdin = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .stdout = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .stderr = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .pseudo_console = if (builtin.os.tag == .windows) pty.pseudo_console else {},
            .pre_exec = if (builtin.os.tag == .windows) null else (struct {
                fn callback(cmd: *Command) void {
                    const sp = cmd.getData(Subprocess) orelse unreachable;
                    sp.childPreExec() catch |err| log.err(
                        "error initializing child: {}",
                        .{err},
                    );
                }
            }).callback,
            .data = self,
            .linux_cgroup = self.linux_cgroup,
        };
        try cmd.start(alloc);
        errdefer killCommand(&cmd) catch |err| {
            log.warn("error killing command during cleanup err={}", .{err});
        };
        log.info("started subcommand path={s} pid={?}", .{ self.args[0], cmd.pid });
        if (comptime builtin.os.tag == .linux) {
            log.info("subcommand cgroup={s}", .{self.linux_cgroup orelse "-"});
        }

        self.command = cmd;
        return switch (builtin.os.tag) {
            .windows => .{
                .read = pty.out_pipe,
                .write = pty.in_pipe,
            },

            else => .{
                .read = pty.master,
                .write = pty.master,
            },
        };
    }

    /// This should be called after fork but before exec in the child process.
    /// To repeat: this function RUNS IN THE FORKED CHILD PROCESS before
    /// exec is called; it does NOT run in the main Ghostty process.
    fn childPreExec(self: *Subprocess) !void {
        // Setup our pty
        try self.pty.?.childPreExec();
    }

    /// Called to notify that we exited externally so we can unset our
    /// running state.
    pub fn externalExit(self: *Subprocess) void {
        self.command = null;
    }

    /// Stop the subprocess. This is safe to call anytime. This will wait
    /// for the subprocess to register that it has been signalled, but not
    /// for it to terminate, so it will not block.
    /// This does not close the pty.
    pub fn stop(self: *Subprocess) void {
        // Kill our command
        if (self.command) |*cmd| {
            // Note: this will also wait for the command to exit, so
            // DO NOT call cmd.wait
            killCommand(cmd) catch |err|
                log.err("error sending SIGHUP to command, may hang: {}", .{err});
            self.command = null;
        }

        // Kill our Flatpak command
        if (FlatpakHostCommand != void) {
            if (self.flatpak_command) |*cmd| {
                killCommandFlatpak(cmd) catch |err|
                    log.err("error sending SIGHUP to command, may hang: {}", .{err});
                _ = cmd.wait() catch |err|
                    log.err("error waiting for command to exit: {}", .{err});
                self.flatpak_command = null;
            }
        }
    }

    /// Resize the pty subprocess. This is safe to call anytime.
    pub fn resize(
        self: *Subprocess,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        self.grid_size = grid_size;
        self.screen_size = screen_size;

        if (self.pty) |*pty| {
            try pty.setSize(.{
                .ws_row = @intCast(grid_size.rows),
                .ws_col = @intCast(grid_size.columns),
                .ws_xpixel = @intCast(screen_size.width),
                .ws_ypixel = @intCast(screen_size.height),
            });
        }
    }

    /// Kill the underlying subprocess. This sends a SIGHUP to the child
    /// process. This also waits for the command to exit and will return the
    /// exit code.
    fn killCommand(command: *Command) !void {
        if (command.pid) |pid| {
            switch (builtin.os.tag) {
                .windows => {
                    if (windows.kernel32.TerminateProcess(pid, 0) == 0) {
                        return windows.unexpectedError(windows.kernel32.GetLastError());
                    }

                    _ = try command.wait(false);
                },

                else => if (getpgid(pid)) |pgid| {
                    // It is possible to send a killpg between the time that
                    // our child process calls setsid but before or simultaneous
                    // to calling execve. In this case, the direct child dies
                    // but grandchildren survive. To work around this, we loop
                    // and repeatedly kill the process group until all
                    // descendents are well and truly dead. We will not rest
                    // until the entire family tree is obliterated.
                    while (true) {
                        if (c.killpg(pgid, c.SIGHUP) < 0) {
                            log.warn("error killing process group pgid={}", .{pgid});
                            return error.KillFailed;
                        }

                        // See Command.zig wait for why we specify WNOHANG.
                        // The gist is that it lets us detect when children
                        // are still alive without blocking so that we can
                        // kill them again.
                        const res = posix.waitpid(pid, std.c.W.NOHANG);
                        if (res.pid != 0) break;
                        std.time.sleep(10 * std.time.ns_per_ms);
                    }
                },
            }
        }
    }

    fn getpgid(pid: c.pid_t) ?c.pid_t {
        // Get our process group ID. Before the child pid calls setsid
        // the pgid will be ours because we forked it. Its possible that
        // we may be calling this before setsid if we are killing a surface
        // VERY quickly after starting it.
        const my_pgid = c.getpgid(0);

        // We loop while pgid == my_pgid. The expectation if we have a valid
        // pid is that setsid will eventually be called because it is the
        // FIRST thing the child process does and as far as I can tell,
        // setsid cannot fail. I'm sure that's not true, but I'd rather
        // have a bug reported than defensively program against it now.
        while (true) {
            const pgid = c.getpgid(pid);
            if (pgid == my_pgid) {
                log.warn("pgid is our own, retrying", .{});
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            // Don't know why it would be zero but its not a valid pid
            if (pgid == 0) return null;

            // If the pid doesn't exist then... we're done!
            if (pgid == c.ESRCH) return null;

            // If we have an error we're done.
            if (pgid < 0) {
                log.warn("error getting pgid for kill", .{});
                return null;
            }

            return pgid;
        }
    }

    /// Kill the underlying process started via Flatpak host command.
    /// This sends a signal via the Flatpak API.
    fn killCommandFlatpak(command: *FlatpakHostCommand) !void {
        try command.signal(c.SIGHUP, true);
    }
};

/// The read thread sits in a loop doing the following pseudo code:
///
///   while (true) { blocking_read(); exit_if_eof(); process(); }
///
/// Almost all terminal-modifying activity is from the pty read, so
/// putting this on a dedicated thread keeps performance very predictable
/// while also almost optimal. "Locking is fast, lock contention is slow."
/// and since we rarely have contention, this is fast.
///
/// This is also empirically fast compared to putting the read into
/// an async mechanism like io_uring/epoll because the reads are generally
/// small.
///
/// We use a basic poll syscall here because we are only monitoring two
/// fds and this is still much faster and lower overhead than any async
/// mechanism.
const ReadThread = struct {
    fn threadMainPosix(fd: posix.fd_t, ev: *EventData, quit: posix.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer posix.close(quit);

        // First thing, we want to set the fd to non-blocking. We do this
        // so that we can try to read from the fd in a tight loop and only
        // check the quit fd occasionally.
        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch |err| {
                log.warn("read thread failed to set flags err={}", .{err});
                log.warn("this isn't a fatal error, but may cause performance issues", .{});
            };
        } else |err| {
            log.warn("read thread failed to get flags err={}", .{err});
            log.warn("this isn't a fatal error, but may cause performance issues", .{});
        }

        // Build up the list of fds we're going to poll. We are looking
        // for data on the pty and our quit notification.
        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            // We try to read from the file descriptor as long as possible
            // to maximize performance. We only check the quit fd if the
            // main fd blocks. This optimizes for the realistic scenario that
            // the data will eventually stop while we're trying to quit. This
            // is always true because we kill the process.
            while (true) {
                const n = posix.read(fd, &buf) catch |err| {
                    switch (err) {
                        // This means our pty is closed. We're probably
                        // gracefully shutting down.
                        error.NotOpenForReading,
                        error.InputOutput,
                        => {
                            log.info("io reader exiting", .{});
                            return;
                        },

                        // No more data, fall back to poll and check for
                        // exit conditions.
                        error.WouldBlock => break,

                        else => {
                            log.err("io reader error err={}", .{err});
                            unreachable;
                        },
                    }
                };

                // This happens on macOS instead of WouldBlock when the
                // child process dies. To be safe, we just break the loop
                // and let our poll happen.
                if (n == 0) break;

                // log.info("DATA: {d}", .{n});
                @call(.always_inline, readInternal, .{ ev, buf[0..n] });
            }

            // Wait for data.
            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on read thread, exiting early err={}", .{err});
                return;
            };

            // If our quit fd is set, we're done.
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("read thread got quit signal", .{});
                return;
            }
        }
    }

    fn threadMainWindows(fd: posix.fd_t, ev: *EventData, quit: posix.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer posix.close(quit);

        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                var n: windows.DWORD = 0;
                if (windows.kernel32.ReadFile(fd, &buf, buf.len, &n, null) == 0) {
                    const err = windows.kernel32.GetLastError();
                    switch (err) {
                        // Check for a quit signal
                        .OPERATION_ABORTED => break,

                        else => {
                            log.err("io reader error err={}", .{err});
                            unreachable;
                        },
                    }
                }

                @call(.always_inline, readInternal, .{ ev, buf[0..n] });
            }

            var quit_bytes: windows.DWORD = 0;
            if (windows.exp.kernel32.PeekNamedPipe(quit, null, 0, null, &quit_bytes, null) == 0) {
                const err = windows.kernel32.GetLastError();
                log.err("quit pipe reader error err={}", .{err});
                unreachable;
            }

            if (quit_bytes > 0) {
                log.info("read thread got quit signal", .{});
                return;
            }
        }
    }
};
