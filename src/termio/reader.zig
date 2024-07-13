const std = @import("std");
const configpkg = @import("../config.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");

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
    exec: Exec,

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

    exec: struct {
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
    },

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
