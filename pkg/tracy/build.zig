const std = @import("std");

/// Directories with our includes.
const root = thisDir() ++ "../../../vendor/tracy/";

pub const pkg = std.build.Pkg{
    .name = "tracy",
    .source = .{ .path = thisDir() ++ "/tracy.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn link(b: *std.build.Builder, step: *std.build.LibExeObjStep) !*std.build.LibExeObjStep {
    const tracy = try buildTracy(b, step);
    step.linkLibrary(tracy);
    step.addIncludePath(root);
    return tracy;
}

pub fn buildTracy(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
) !*std.build.LibExeObjStep {
    const target = step.target;
    const lib = b.addStaticLibrary("tracy", null);
    lib.setTarget(step.target);
    lib.setBuildMode(step.build_mode);

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    try flags.appendSlice(&.{
        "-DTRACY_ENABLE",
        "-fno-sanitize=undefined",
    });

    if (target.isWindows()) {
        try flags.appendSlice(&.{
            "-D_WIN32_WINNT=0x601",
        });
    }

    lib.addIncludePath(root);
    lib.addCSourceFile(try std.fs.path.join(
        lib.builder.allocator,
        &.{ root, "TracyClient.cpp" },
    ), flags.items);

    lib.linkLibC();
    lib.linkSystemLibrary("c++");

    if (lib.target.isWindows()) {
        lib.linkSystemLibrary("Advapi32");
        lib.linkSystemLibrary("User32");
        lib.linkSystemLibrary("Ws2_32");
        lib.linkSystemLibrary("DbgHelp");
    }

    return lib;
}
