const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = target;
    _ = optimize;
}

pub fn addPaths(b: *std.Build, step: anytype) !void {
    // The active SDK we want to use
    const sdk = "MacOSX14.sdk";

    // Get the path to our active Xcode installation. If this fails then
    // the zig build will fail.
    const path = std.mem.trim(
        u8,
        b.run(&.{ "xcode-select", "--print-path" }),
        " \r\n",
    );

    step.addSystemFrameworkPath(.{
        .cwd_relative = b.pathJoin(&.{
            path,
            "Platforms/MacOSX.platform/Developer/SDKs/" ++ sdk ++ "/System/Library/Frameworks",
        }),
    });
    step.addSystemIncludePath(.{
        .cwd_relative = b.pathJoin(&.{
            path,
            "Platforms/MacOSX.platform/Developer/SDKs/" ++ sdk ++ "/usr/include",
        }),
    });
    step.addLibraryPath(.{
        .cwd_relative = b.pathJoin(&.{
            path,
            "Platforms/MacOSX.platform/Developer/SDKs/" ++ sdk ++ "/usr/lib",
        }),
    });
}
