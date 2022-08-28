const std = @import("std");

/// Directories with our includes.
const root = thisDir() ++ "../../../vendor/harfbuzz/";
const include_path = root ++ "include";

pub const include_paths = .{include_path};

pub const pkg = std.build.Pkg{
    .name = "harfbuzz",
    .source = .{ .path = thisDir() ++ "/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub const Options = struct {
    freetype: Freetype = .{},

    pub const Freetype = struct {
        enabled: bool = false,
        step: ?*std.build.LibExeObjStep = null,
        include: ?[]const []const u8 = null,
    };
};

pub fn link(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    const lib = try buildHarfbuzz(b, step, opt);
    step.linkLibrary(lib);
    step.addIncludePath(include_path);
    return lib;
}

pub fn buildHarfbuzz(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    const lib = b.addStaticLibrary("harfbuzz", null);
    lib.setTarget(step.target);
    lib.setBuildMode(step.build_mode);

    // Include
    lib.addIncludePath(include_path);

    // Link
    lib.linkLibC();
    lib.linkLibCpp();
    if (opt.freetype.enabled) {
        if (opt.freetype.step) |freetype|
            lib.linkLibrary(freetype)
        else
            lib.linkSystemLibrary("freetype2");

        if (opt.freetype.include) |dirs|
            for (dirs) |dir| lib.addIncludePath(dir);
    }

    // Compile
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    try flags.appendSlice(&.{
        "-DHAVE_UNISTD_H",
        "-DHAVE_SYS_MMAN_H",
        "-DHAVE_STDBOOL_H",

        // We always have pthread
        "-DHAVE_PTHREAD=1",
    });
    if (opt.freetype.enabled) try flags.appendSlice(&.{
        "-DHAVE_FREETYPE=1",

        // Let's just assume a new freetype
        "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
        "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
        "-DHAVE_FT_DONE_MM_VAR=1",
        "-DHAVE_FT_GET_TRANSFORM=1",
    });

    // C files
    lib.addCSourceFiles(srcs, flags.items);

    return lib;
}

const srcs = &.{
    root ++ "src/harfbuzz.cc",
};
