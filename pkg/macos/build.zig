const std = @import("std");
const builtin = @import("builtin");
const apple_sdk = @import("apple_sdk");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("macos", .{ .source_file = .{ .path = "main.zig" } });

    const lib = b.addStaticLibrary(.{
        .name = "macos",
        .target = target,
        .optimize = optimize,
    });

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    lib.addCSourceFile(.{
        .file = .{ .path = "os/log.c" },
        .flags = flags.items,
    });
    lib.addCSourceFile(.{
        .file = .{ .path = "text/ext.c" },
        .flags = flags.items,
    });
    lib.linkFramework("Carbon");
    lib.linkFramework("CoreFoundation");
    lib.linkFramework("CoreGraphics");
    lib.linkFramework("CoreText");
    try apple_sdk.addPaths(b, lib);

    b.installArtifact(lib);
}
