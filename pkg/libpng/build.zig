const std = @import("std");

/// Directories with our includes.
const root = thisDir() ++ "../../../vendor/libpng/";
const include_path = root;
const include_path_pnglibconf = thisDir();

pub const include_paths = .{ include_path, include_path_pnglibconf };

pub const pkg = std.build.Pkg{
    .name = "libpng",
    .source = .{ .path = thisDir() ++ "/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub const Options = struct {
    zlib: Zlib = .{},

    pub const Zlib = struct {
        step: ?*std.build.LibExeObjStep = null,
        include: ?[]const []const u8 = null,
    };
};

pub fn link(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    const lib = try buildLib(b, step, opt);
    step.linkLibrary(lib);
    step.addIncludePath(include_path);
    return lib;
}

pub fn buildLib(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    const target = step.target;
    const lib = b.addStaticLibrary("png", null);
    lib.setTarget(step.target);
    lib.setBuildMode(step.build_mode);

    // Include
    lib.addIncludePath(include_path);
    lib.addIncludePath(include_path_pnglibconf);

    // Link
    lib.linkLibC();
    if (target.isLinux()) {
        lib.linkSystemLibrary("m");
    }

    if (opt.zlib.step) |zlib|
        lib.linkLibrary(zlib)
    else
        lib.linkSystemLibrary("z");

    if (opt.zlib.include) |dirs|
        for (dirs) |dir| lib.addIncludePath(dir);

    // Compile
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    try flags.appendSlice(&.{
        "-DPNG_ARM_NEON_OPT=0",
        "-DPNG_POWERPC_VSX_OPT=0",
        "-DPNG_INTEL_SSE_OPT=0",
        "-DPNG_MIPS_MSA_OPT=0",
    });

    // C files
    lib.addCSourceFiles(srcs, flags.items);

    return lib;
}

const srcs = &.{
    root ++ "png.c",
    root ++ "pngerror.c",
    root ++ "pngget.c",
    root ++ "pngmem.c",
    root ++ "pngpread.c",
    root ++ "pngread.c",
    root ++ "pngrio.c",
    root ++ "pngrtran.c",
    root ++ "pngrutil.c",
    root ++ "pngset.c",
    root ++ "pngtrans.c",
    root ++ "pngwio.c",
    root ++ "pngwrite.c",
    root ++ "pngwtran.c",
    root ++ "pngwutil.c",
};
