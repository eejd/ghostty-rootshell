const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const termio = @import("../termio.zig");
const pty_pkg = @import("../pty.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.termio_pipe);

/// Pipe backend: Uses pipes instead of PTY for platforms where PTY isn't available
/// or when external I/O management is preferred. The external layer (e.g., Swift)
/// manages all I/O through these pipes.
pub const Pipe = @This();

/// Input pipe: Swift → Ghostty (shell output to display)
/// - master_fd: Ghostty reads shell output from here
/// - slave_fd: Swift writes shell output here
master_fd: posix.fd_t,
slave_fd: posix.fd_t,

/// Response pipe: Ghostty → Swift (terminal responses like cursor position)
/// - response_read_fd: Swift reads terminal responses from here
/// - response_write_fd: Ghostty writes terminal responses here
response_read_fd: posix.fd_t,
response_write_fd: posix.fd_t,

/// Current window size (tracked for resize operations)
current_size: pty_pkg.winsize,

pub const Config = struct {
    /// Working directory (optional)
    cwd: ?[]const u8 = null,
};

pub const Options = struct {
    /// Working directory
    cwd: ?[]const u8 = null,
};

pub fn init(alloc: Allocator, opts: Options) !Pipe {
    _ = alloc;
    _ = opts;

    // Create input pipe (Swift → Ghostty)
    const input_fds = try posix.pipe();
    errdefer posix.close(input_fds[0]);
    errdefer posix.close(input_fds[1]);

    const master_fd = input_fds[0]; // Read end
    const slave_fd = input_fds[1];  // Write end

    // Create response pipe (Ghostty → Swift)
    const response_fds = try posix.pipe();
    errdefer posix.close(response_fds[0]);
    errdefer posix.close(response_fds[1]);

    const response_read_fd = response_fds[0]; // Read end (for Swift)
    const response_write_fd = response_fds[1]; // Write end (for Ghostty)

    // Set all pipe ends to non-blocking mode
    const master_flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(master_fd, posix.F.SETFL, master_flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

    const slave_flags = try posix.fcntl(slave_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(slave_fd, posix.F.SETFL, slave_flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

    const resp_read_flags = try posix.fcntl(response_read_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(response_read_fd, posix.F.SETFL, resp_read_flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

    const resp_write_flags = try posix.fcntl(response_write_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(response_write_fd, posix.F.SETFL, resp_write_flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

    log.info("Pipe: created input pipe (master_fd={}, slave_fd={})", .{ master_fd, slave_fd });
    log.info("Pipe: created response pipe (response_read_fd={}, response_write_fd={})", .{ response_read_fd, response_write_fd });

    return .{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
        .response_read_fd = response_read_fd,
        .response_write_fd = response_write_fd,
        .current_size = .{
            .ws_row = 24,
            .ws_col = 80,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        },
    };
}

pub fn deinit(self: *Pipe) void {
    // Close all pipe FDs
    if (self.master_fd >= 0) posix.close(self.master_fd);
    if (self.slave_fd >= 0) posix.close(self.slave_fd);
    if (self.response_read_fd >= 0) posix.close(self.response_read_fd);
    if (self.response_write_fd >= 0) posix.close(self.response_write_fd);
    log.info("Pipe cleaned up", .{});
}

/// Initialize terminal state (called before thread starts)
pub fn initTerminal(self: *Pipe, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
    // Nothing to do - external layer handles shell
}

/// Thread data for this backend
pub const ThreadData = struct {
    /// Reference to the Termio instance (needed for processOutput callback)
    io: *termio.Termio,

    /// Buffer for reading from pipe
    read_buf: [4096]u8 = undefined,

    /// Stream for reading from master_fd (pipe read end)
    read_stream: ?xev.Stream = null,

    /// Completion for stream read operations
    read_c: xev.Completion = undefined,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;

        // Clean up stream if initialized
        if (self.read_stream) |*stream| {
            stream.deinit();
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

/// Called when thread starts
pub fn threadEnter(
    self: *Pipe,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // Initialize the stream for reading from master_fd (pipe read end)
    var read_stream = xev.Stream.initFd(self.master_fd);
    errdefer read_stream.deinit();

    // Initialize the thread data backend to pipe variant
    td.backend = .{ .pipe = .{ .io = io, .read_stream = read_stream } };

    // Start reading from the pipe
    td.backend.pipe.read_stream.?.read(
        td.loop,
        &td.backend.pipe.read_c,
        .{ .slice = &td.backend.pipe.read_buf },
        termio.Termio.ThreadData,
        td,
        readCallback,
    );

    log.info("termio thread started with pipe stream (master_fd={})", .{self.master_fd});
}

/// Callback when data is read from the pipe (shell output from Swift)
fn readCallback(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    c: *xev.Completion,
    _: xev.Stream,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const td = td_.?;

    // Get the data that was read
    const n = r catch |err| {
        log.warn("pipe read error: {}", .{err});
        // On error, stop reading
        return .disarm;
    };

    if (n == 0) {
        // EOF - pipe closed (Swift side closed slave_fd)
        log.info("pipe EOF, shell session ended", .{});
        return .disarm;
    }

    // Process the data through the terminal emulator
    const data = td.backend.pipe.read_buf[0..n];
    log.debug("pipe read: {} bytes", .{n});

    // Write to terminal (this will parse VT sequences and update the screen)
    td.backend.pipe.io.processOutput(data);

    // Continue reading
    td.backend.pipe.read_stream.?.read(
        td.loop,
        c,
        .{ .slice = &td.backend.pipe.read_buf },
        termio.Termio.ThreadData,
        td,
        readCallback,
    );

    return .disarm;
}

/// Called when thread exits
pub fn threadExit(self: *Pipe, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
    log.info("termio thread exited", .{});
}

/// Handle focus changes
pub fn focusGained(
    self: *Pipe,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // Could send focus events to Swift layer via callback if needed
}

/// Handle terminal resize
pub fn resize(
    self: *Pipe,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    // Update tracked size (Swift layer will handle actual resize via setSize callback)
    self.current_size = .{
        .ws_row = @intCast(grid_size.rows),
        .ws_col = @intCast(grid_size.columns),
        .ws_xpixel = @intCast(screen_size.width),
        .ws_ypixel = @intCast(screen_size.height),
    };

    log.info("resized terminal: {}x{}", .{ grid_size.rows, grid_size.columns });
}

/// Queue write to response pipe (terminal responses like cursor position)
/// This is called when Ghostty needs to send data back to the external layer
pub fn queueWrite(
    self: *Pipe,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;

    if (data.len == 0) return;

    // Write terminal responses to the response pipe for Swift to read
    var total_written: usize = 0;
    while (total_written < data.len) {
        const remaining = data[total_written..];
        const written = posix.write(self.response_write_fd, remaining) catch |err| {
            // For non-blocking FD, WouldBlock means pipe buffer is full
            // Log and return - data may be lost but better than blocking
            log.warn("failed to write to response pipe: {}", .{err});
            return err;
        };

        if (written == 0) {
            log.warn("response pipe closed", .{});
            return error.BrokenPipe;
        }

        total_written += written;
    }

    // Handle linefeed if requested
    if (linefeed) {
        _ = posix.write(self.response_write_fd, "\n") catch |err| {
            log.err("failed to write linefeed to response pipe: {}", .{err});
            return err;
        };
    }

    log.debug("wrote {} bytes to response pipe: {s}", .{ data.len, data[0..@min(data.len, 50)] });
}

/// Handle abnormal child exit
pub fn childExitedAbnormally(
    self: *Pipe,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
    // External layer (Swift) manages the shell, so we don't handle exits here
}
