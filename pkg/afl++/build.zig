const std = @import("std");

pub fn addInstrumentedExe(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
) ?std.Build.LazyPath {
    const pkg = b.dependencyFromBuildZig(@This(), .{});

    const run_afl_cc = b.addSystemCommand(&.{
        b.findProgram(&.{"afl-cc"}, &.{}) catch
            @panic("Could not find 'afl-cc', which is required to build"),
        "-O3",
    });
    _ = obj.getEmittedBin(); // hack around build system bug
    run_afl_cc.addArg("-o");
    const fuzz_exe = run_afl_cc.addOutputFileArg(obj.name);
    run_afl_cc.addFileArg(pkg.path("afl.c"));
    run_afl_cc.addFileArg(obj.getEmittedLlvmBc());
    return fuzz_exe;
}

pub fn build(b: *std.Build) !void {
    _ = b;
}
