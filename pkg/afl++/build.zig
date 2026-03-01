const std = @import("std");

/// Creates a build step that produces an AFL++-instrumented fuzzing
/// executable.
///
/// Returns a `LazyPath` to the resulting fuzzing executable.
pub fn addInstrumentedExe(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
) std.Build.LazyPath {
    // Force the build system to produce the binary artifact even though we
    // only consume the LLVM bitcode below. Without this, the dependency
    // tracking doesn't wire up correctly.
    _ = obj.getEmittedBin();

    const pkg = b.dependencyFromBuildZig(
        @This(),
        .{},
    );

    const afl_cc = b.addSystemCommand(&.{
        b.findProgram(&.{"afl-cc"}, &.{}) catch
            @panic("Could not find 'afl-cc', which is required to build"),
        "-O3",
    });
    afl_cc.addArg("-o");
    const fuzz_exe = afl_cc.addOutputFileArg(obj.name);
    afl_cc.addFileArg(pkg.path("afl.c"));
    afl_cc.addFileArg(obj.getEmittedLlvmBc());
    return fuzz_exe;
}

// Required so `zig build` works although it does nothing.
pub fn build(b: *std.Build) !void {
    _ = b;
}
