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
const StreamHandler = @import("stream_handler.zig").StreamHandler;
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
subprocess: termio.Exec,

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

/// The pointer to the read data. This is only valid while the termio thread
/// is alive. This is protected by the renderer state lock.
read_data: ?*ReadData = null,

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

    var subprocess = try termio.Exec.init(alloc, opts);
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
    var read_data_ptr = try alloc.create(ReadData);
    errdefer alloc.destroy(read_data_ptr);

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
    read_data_ptr.* = .{
        .renderer_state = self.renderer_state,
        .renderer_wakeup = self.renderer_wakeup,
        .renderer_mailbox = self.renderer_mailbox,
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
    errdefer read_data_ptr.deinit();

    // Start our reader thread
    const read_thread = try std.Thread.spawn(
        .{},
        if (builtin.os.tag == .windows) ReadThread.threadMainWindows else ReadThread.threadMainPosix,
        .{ pty_fds.read, read_data_ptr, pipe[0] },
    );
    read_thread.setName("io-reader") catch {};

    // Return our thread data
    data.* = .{
        .alloc = alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .writer_mailbox = thread.mailbox,
        .writer_wakeup = thread.wakeup,
        .reader = .{ .exec = .{
            .start = process_start,
            .abnormal_runtime_threshold_ms = self.config.abnormal_runtime_threshold_ms,
            .wait_after_command = self.config.wait_after_command,
            .write_stream = stream,
            .process = process,
        } },
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = if (builtin.os.tag == .windows) pty_fds.read else {},
        .read_thread_data = read_data_ptr,
    };

    // Start our process watcher
    process.wait(
        &thread.loop,
        &data.reader.exec.process_wait_c,
        ThreadData,
        data,
        processExit,
    );
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
    td.read_thread_data.terminal_stream.handler.changeConfig(&self.config);
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
    switch (td.reader) {
        .manual => {},
        .exec => try self.queueWriteExec(
            td,
            data,
            linefeed,
        ),
    }
}

fn queueWriteExec(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    const exec = &td.reader.exec;

    // If our process is exited then we send our surface a message
    // about it but we don't queue any more writes.
    if (exec.exited) {
        _ = td.surface_mailbox.push(.{
            .child_exited = {},
        }, .{ .forever = {} });
        return;
    }

    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const req = try exec.write_req_pool.getGrow(self.alloc);
        const buf = try exec.write_buf_pool.getGrow(self.alloc);
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

        exec.write_stream.queueWrite(
            td.loop,
            &exec.write_queue,
            req,
            .{ .slice = slice },
            termio.reader.ThreadData.Exec,
            exec,
            ttyWrite,
        );
    }
}

/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) !void {
    // We are modifying terminal state from here on out and we need
    // the lock to grab our read data.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // If we don't have read data, we can't process it.
    const rd = self.read_data orelse return error.ReadDataNull;
    processOutputLocked(rd, buf);
}

/// Process output when you ahve the read data pointer.
pub fn processOutputReadData(rd: *ReadData, buf: []const u8) void {
    rd.renderer_state.mutex.lock();
    defer rd.renderer_state.mutex.unlock();
    processOutputLocked(rd, buf);
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(rd: *ReadData, buf: []const u8) void {
    // Schedule a render. We can call this first because we have the lock.
    rd.terminal_stream.handler.queueRender() catch unreachable;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    const now = rd.loop.now();
    if (now - rd.last_cursor_reset > 500) {
        rd.last_cursor_reset = now;
        _ = rd.renderer_mailbox.push(.{
            .reset_cursor_blink = {},
        }, .{ .forever = {} });
    }

    // If we have an inspector, we enter SLOW MODE because we need to
    // process a byte at a time alternating between the inspector handler
    // and the termio handler. This is very slow compared to our optimizations
    // below but at least users only pay for it if they're using the inspector.
    if (rd.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(buf[i .. i + 1]) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };

            rd.terminal_stream.next(byte) catch |err|
                log.err("error processing terminal data: {}", .{err});
        }
    } else {
        rd.terminal_stream.nextSlice(buf) catch |err|
            log.err("error processing terminal data: {}", .{err});
    }

    // If our stream handling caused messages to be sent to the writer
    // thread, then we need to wake it up so that it processes them.
    if (rd.terminal_stream.handler.writer_messaged) {
        rd.terminal_stream.handler.writer_messaged = false;
        // TODO
        // rd.writer_wakeup.notify() catch |err| {
        //     log.warn("failed to wake up writer thread err={}", .{err});
        // };
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

    /// The event loop associated with this thread. This is owned by
    /// the Thread but we have a pointer so we can queue new work to it.
    loop: *xev.Loop,

    /// The shared render state
    renderer_state: *renderer.State,

    /// Mailboxes for different threads
    surface_mailbox: apprt.surface.Mailbox,
    writer_mailbox: *termio.Mailbox,
    writer_wakeup: xev.Async,

    /// Data associated with the reader implementation (i.e. pty/exec state)
    reader: termio.reader.ThreadData,

    /// Our read thread
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    read_thread_fd: if (builtin.os.tag == .windows) posix.fd_t else void,
    read_thread_data: *ReadData,

    pub fn deinit(self: *ThreadData) void {
        posix.close(self.read_thread_pipe);
        self.read_thread_data.deinit();
        self.reader.deinit(self.alloc);
        self.alloc.destroy(self.read_thread_data);
        self.* = undefined;
    }
};

/// The data required for the read thread.
pub const ReadData = struct {
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

    /// The event loop,
    loop: *xev.Loop,

    /// Last time the cursor was reset. This is used to prevent message
    /// flooding with cursor resets.
    last_cursor_reset: i64 = 0,

    pub fn deinit(self: *ReadData) void {
        // Clear any StreamHandler state
        self.terminal_stream.handler.deinit();
        self.terminal_stream.deinit();
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
        _ = td.writer_mailbox.push(.{
            .child_exited_abnormally = .{
                .exit_code = exit_code,
                .runtime_ms = runtime,
            },
        }, .{ .forever = {} });
        td.writer_wakeup.notify() catch break :runtime;

        return .disarm;
    }

    // If we're purposely waiting then we just return since the process
    // exited flag is set to true. This allows the terminal window to remain
    // open.
    if (execdata.wait_after_command) {
        // We output a message so that the user knows whats going on and
        // doesn't think their terminal just froze.
        terminal: {
            td.renderer_state.mutex.lock();
            defer td.renderer_state.mutex.unlock();
            const t = td.renderer_state.terminal;
            t.carriageReturn();
            t.linefeed() catch break :terminal;
            t.printString("Process exited. Press any key to close the terminal.") catch
                break :terminal;
            t.modes.set(.cursor_visible, false);
        }

        return .disarm;
    }

    // Notify our surface we want to close
    _ = td.surface_mailbox.push(.{
        .child_exited = {},
    }, .{ .forever = {} });

    return .disarm;
}

fn ttyWrite(
    td_: ?*termio.reader.ThreadData.Exec,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.Stream.WriteError!usize,
) xev.CallbackAction {
    const td = td_.?;
    td.write_req_pool.put();
    td.write_buf_pool.put();

    const d = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };
    _ = d;
    //log.info("WROTE: {d}", .{d});

    return .disarm;
}

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
    fn threadMainPosix(fd: posix.fd_t, ev: *ReadData, quit: posix.fd_t) void {
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
                @call(.always_inline, processOutputReadData, .{ ev, buf[0..n] });
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

    fn threadMainWindows(fd: posix.fd_t, ev: *ReadData, quit: posix.fd_t) void {
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

                @call(.always_inline, processOutputReadData, .{ ev, buf[0..n] });
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
