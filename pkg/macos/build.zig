const std = @import("std");
const builtin = @import("builtin");

pub const pkg = std.build.Pkg{
    .name = "macos",
    .source = .{ .path = thisDir() ++ "/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub const Options = struct {};

pub fn link(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    _ = opt;
    const lib = b.addStaticLibrary("macos", null);
    step.linkFramework("CoreFoundation");
    step.linkFramework("CoreText");
    return lib;
}
