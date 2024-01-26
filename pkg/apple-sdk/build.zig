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
    // Get the path to our active SDK installation. If this fails then
    // the zig build will fail. We store this in a struct variable so its
    // static and only calculated once per build.
    const Path = struct {
        var value: ?[]const u8 = null;
    };
    const path = Path.value orelse path: {
        const path = std.zig.system.darwin.getSdk(b.allocator, m.resolved_target.?.result) orelse "";
        Path.value = path;
        break :path path;
    };
    // The active SDK we want to use
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/lib" }) });
}
