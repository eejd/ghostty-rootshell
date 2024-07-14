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
    exec: termio.Exec.ThreadData,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .manual => {},
            .exec => |*exec| exec.deinit(alloc),
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
