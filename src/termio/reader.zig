const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const xev = @import("xev");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const shell_integration = @import("shell_integration.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const SegmentedPool = @import("../segmented_pool.zig").SegmentedPool;
const Pty = @import("../pty.zig").Pty;

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// The kinds of readers.
pub const Kind = std.meta.Tag(Config);

/// Configuration for the various reader types.
pub const Config = union(enum) {
    /// Manual means that the termio caller will handle reading input
    /// and passing it to the termio implementation. Note that even if you
    /// select a different reader, you can always still manually provide input;
    /// this config just makes it so that it is ONLY manual input.
    manual: void,

    /// Exec uses posix exec to run a command with a pty.
    exec: Config.Exec,

    pub const Exec = struct {
        command: ?[]const u8 = null,
        shell_integration: configpkg.Config.ShellIntegration = .detect,
        shell_integration_features: configpkg.Config.ShellIntegrationFeatures = .{},
        working_directory: ?[]const u8 = null,
        linux_cgroup: Command.LinuxCgroup = Command.linux_cgroup_default,
    };
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    manual: void,
    exec: ThreadData.Exec,

    pub const Exec = struct {
        /// Process start time and boolean of whether its already exited.
        start: std.time.Instant,
        exited: bool = false,

        /// The number of milliseconds below which we consider a process
        /// exit to be abnormal. This is used to show an error message
        /// when the process exits too quickly.
        abnormal_runtime_threshold_ms: u32,

        /// If true, do not immediately send a child exited message to the
        /// surface to close the surface when the command exits. If this is
        /// false we'll show a process exited message and wait for user input
        /// to close the surface.
        wait_after_command: bool,

        /// The data stream is the main IO for the pty.
        write_stream: xev.Stream,

        /// The process watcher
        process: xev.Process,

        /// This is the pool of available (unused) write requests. If you grab
        /// one from the pool, you must put it back when you're done!
        write_req_pool: SegmentedPool(xev.Stream.WriteRequest, WRITE_REQ_PREALLOC) = .{},

        /// The pool of available buffers for writing to the pty.
        write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

        /// The write queue for the data stream.
        write_queue: xev.Stream.WriteQueue = .{},

        /// This is used for both waiting for the process to exit and then
        /// subsequently to wait for the data_stream to close.
        process_wait_c: xev.Completion = .{},
    };

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .manual => {},
            .exec => |*exec| {
                // Clear our write pools. We know we aren't ever going to do
                // any more IO since we stop our data stream below so we can just
                // drop this.
                exec.write_req_pool.deinit(alloc);
                exec.write_buf_pool.deinit(alloc);

                // Stop our process watcher
                exec.process.deinit();

                // Stop our write stream
                exec.write_stream.deinit();
            },
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        switch (self.*) {
            .manual => {},
            .exec => |*exec| {
                exec.abnormal_runtime_threshold_ms = config.abnormal_runtime_threshold_ms;
                exec.wait_after_command = config.wait_after_command;
            },
        }
    }
};
