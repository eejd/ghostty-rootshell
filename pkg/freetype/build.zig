const std = @import("std");

/// Directories with our includes.
const root = thisDir() ++ "../../../vendor/freetype/";
const include_path = root ++ "include";
const include_path_self = thisDir();

pub const pkg = std.build.Pkg{
    .name = "freetype",
    .source = .{ .path = thisDir() ++ "/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn link(b: *std.build.Builder, step: *std.build.LibExeObjStep) !*std.build.LibExeObjStep {
    const lib = try buildFreetype(b, step);
    step.linkLibrary(lib);
    step.addIncludePath(include_path);
    step.addIncludePath(include_path_self);
    return lib;
}

pub fn buildFreetype(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
) !*std.build.LibExeObjStep {
    const target = step.target;
    const lib = b.addStaticLibrary("freetype", null);
    lib.setTarget(step.target);
    lib.setBuildMode(step.build_mode);

    // Include
    lib.addIncludePath(include_path);

    // Link
    lib.linkLibC();

    // Compile
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    try flags.appendSlice(&.{
        "-DFT2_BUILD_LIBRARY",

        "-DHAVE_UNISTD_H",
        "-DHAVE_FCNTL_H",
    });

    // C files
    lib.addCSourceFiles(srcs, flags.items);
    switch (target.getOsTag()) {
        .linux => lib.addCSourceFile(root ++ "builds/unix/ftsystem.c", flags.items),
        .windows => lib.addCSourceFile(root ++ "builds/windows/ftsystem.c", flags.items),
        else => lib.addCSourceFile(root ++ "src/base/ftsystem.c", flags.items),
    }
    switch (target.getOsTag()) {
        .windows => {
            lib.addCSourceFile(root ++ "builds/windows/ftdebug.c", flags.items);
            lib.addCSourceFile(root ++ "src/base/ftver.c", flags.items);
        },
        else => lib.addCSourceFile(root ++ "src/base/ftdebug.c", flags.items),
    }

    return lib;
}

const srcs = &.{
    root ++ "src/autofit/autofit.c",
    root ++ "src/base/ftbase.c",
    root ++ "src/base/ftbbox.c",
    root ++ "src/base/ftbdf.c",
    root ++ "src/base/ftbitmap.c",
    root ++ "src/base/ftcid.c",
    root ++ "src/base/ftfstype.c",
    root ++ "src/base/ftgasp.c",
    root ++ "src/base/ftglyph.c",
    root ++ "src/base/ftgxval.c",
    root ++ "src/base/ftinit.c",
    root ++ "src/base/ftmm.c",
    root ++ "src/base/ftotval.c",
    root ++ "src/base/ftpatent.c",
    root ++ "src/base/ftpfr.c",
    root ++ "src/base/ftstroke.c",
    root ++ "src/base/ftsynth.c",
    root ++ "src/base/fttype1.c",
    root ++ "src/base/ftwinfnt.c",
    root ++ "src/bdf/bdf.c",
    root ++ "src/bzip2/ftbzip2.c",
    root ++ "src/cache/ftcache.c",
    root ++ "src/cff/cff.c",
    root ++ "src/cid/type1cid.c",
    root ++ "src/gzip/ftgzip.c",
    root ++ "src/lzw/ftlzw.c",
    root ++ "src/pcf/pcf.c",
    root ++ "src/pfr/pfr.c",
    root ++ "src/psaux/psaux.c",
    root ++ "src/pshinter/pshinter.c",
    root ++ "src/psnames/psnames.c",
    root ++ "src/raster/raster.c",
    root ++ "src/sdf/sdf.c",
    root ++ "src/sfnt/sfnt.c",
    root ++ "src/smooth/smooth.c",
    root ++ "src/svg/svg.c",
    root ++ "src/truetype/truetype.c",
    root ++ "src/type1/type1.c",
    root ++ "src/type42/type42.c",
    root ++ "src/winfonts/winfnt.c",
};
