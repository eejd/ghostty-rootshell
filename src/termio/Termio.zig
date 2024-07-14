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

    // Setup our reader.
    // TODO: for manual, we need to set the terminal width/height
    var subprocess = try termio.Exec.init(alloc, opts, &term);
    errdefer subprocess.deinit();

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

    // Setup our data that is used for callbacks
    var read_data_ptr = try alloc.create(ReadData);
    errdefer alloc.destroy(read_data_ptr);

    // Wakeup watcher for the writer thread.
    var wakeup = try xev.Async.init();
    errdefer wakeup.deinit();

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

    // Setup our thread data
    data.* = .{
        .alloc = alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .writer_mailbox = thread.mailbox,
        .writer_wakeup = thread.wakeup,
        .read_data = read_data_ptr,

        // Placeholder until setup below
        .reader = .{ .manual = {} },
    };

    // Setup our reader
    try self.subprocess.threadEnter(alloc, self, data);
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
    self.subprocess.threadExit(data);
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
    td.read_data.terminal_stream.handler.changeConfig(&self.config);
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
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    const t = self.renderer_state.terminal;
    try self.subprocess.childExitedAbnormally(self.alloc, t, exit_code, runtime_ms);
}

pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.subprocess.queueWrite(self.alloc, td, data, linefeed);
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
    read_data: *ReadData,

    pub fn deinit(self: *ThreadData) void {
        self.reader.deinit(self.alloc);
        self.read_data.deinit();
        self.alloc.destroy(self.read_data);
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
