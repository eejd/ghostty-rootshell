const std = @import("std");
const builtin = @import("builtin");

pub fn module(b: *std.Build) *std.build.Module {
    return b.createModule(.{
        .source_file = .{ .path = (comptime thisDir()) ++ "/main.zig" },
    });
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub const Options = struct {};

pub fn link(
    b: *std.Build,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    _ = opt;
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    const lib = b.addStaticLibrary(.{
        .name = "macos",
        .target = step.target,
        .optimize = step.optimize,
    });
    step.addCSourceFile(comptime thisDir() ++ "/os/log.c", flags.items);
    step.addCSourceFile(comptime thisDir() ++ "/text/ext.c", flags.items);
    step.linkFramework("CoreFoundation");
    step.linkFramework("CoreText");
    return lib;
}
