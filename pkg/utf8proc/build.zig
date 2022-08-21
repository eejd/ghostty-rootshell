const std = @import("std");

/// Directories with our includes.
const root = thisDir() ++ "../../../vendor/utf8proc/";
const include_path = root;

pub const include_paths = .{include_path};

pub const pkg = std.build.Pkg{
    .name = "utf8proc",
    .source = .{ .path = thisDir() ++ "/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn link(b: *std.build.Builder, step: *std.build.LibExeObjStep) !*std.build.LibExeObjStep {
    const lib = try buildLib(b, step);
    step.linkLibrary(lib);
    step.addIncludePath(include_path);
    return lib;
}

pub fn buildLib(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
) !*std.build.LibExeObjStep {
    const lib = b.addStaticLibrary("utf8proc", null);
    lib.setTarget(step.target);
    lib.setBuildMode(step.build_mode);

    // Include
    lib.addIncludePath(include_path);

    // Link
    lib.linkLibC();

    // Compile
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    // C files
    lib.addCSourceFiles(srcs, flags.items);

    return lib;
}

const srcs = &.{
    root ++ "utf8proc.c",
};
