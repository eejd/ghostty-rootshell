const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = target;
    _ = optimize;
}

/// Add the SDK framework, include, and library paths to the given module.
/// The module target is used to determine the SDK to use so it must have
/// a resolved target.
pub fn addPaths(b: *std.Build, m: *std.Build.Module) !void {
    // The active SDK we want to use
    const sdk = try SDK.fromTarget(m.resolved_target.?.result);

    // Get the path to our active Xcode installation. If this fails then
    // the zig build will fail.
    const path = std.mem.trim(
        u8,
        b.run(&.{ "xcode-select", "--print-path" }),
        " \r\n",
    );

    // Base path
    const base = b.fmt("{s}/Platforms/{s}.platform/Developer/SDKs/{s}{s}.sdk", .{
        path,
        sdk.platform,
        sdk.platform,
        sdk.version,
    });

    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ base, "/System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ base, "/usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ base, "/usr/lib" }) });
}

const SDK = struct {
    platform: []const u8,
    version: []const u8,

    pub fn fromTarget(target: std.Target) !SDK {
        return switch (target.os.tag) {
            .macos => .{ .platform = "MacOSX", .version = "14" },
            else => {
                std.log.err("unsupported os={}", .{target.os.tag});
                return error.UnsupportedOS;
            },
        };
    }
};
