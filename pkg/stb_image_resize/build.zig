const std = @import("std");

/// Directories with our includes.
const root = thisDir();
pub const include_paths = [_][]const u8{
    root,
};

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
    const lib = try buildStbImageResize(b, step, opt);
    step.linkLibrary(lib);
    inline for (include_paths) |path| step.addIncludePath(.{ .path = path });
    return lib;
}

pub fn buildStbImageResize(
    b: *std.Build,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    _ = opt;

    const lib = b.addStaticLibrary(.{
        .name = "stb_image_resize",
        .target = step.target,
        .optimize = step.optimize,
    });

    // Include
    inline for (include_paths) |path| lib.addIncludePath(.{ .path = path });

    // Link
    lib.linkLibC();

    // Compile
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        //"-fno-sanitize=undefined",
    });

    // C files
    lib.addCSourceFile(.{
        .file = .{ .path = root ++ "/stb_image_resize.c" },
        .flags = flags.items,
    });

    return lib;
}
