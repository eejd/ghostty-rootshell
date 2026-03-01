const std = @import("std");
const afl = @import("afl");

const FuzzTarget = struct {
    name: []const u8,
    source: []const u8,
    corpus: []const u8,
};

const fuzz_targets = [_]FuzzTarget{
    .{
        .name = "fuzz-vt-parser",
        .source = "src/fuzz_vt_parser.zig",
        .corpus = "corpus/vt-parser-cmin",
    },
    .{
        .name = "fuzz-vt-stream",
        .source = "src/fuzz_vt_stream.zig",
        .corpus = "corpus/vt-stream-initial",
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const run_step = b.step("run", "Run the default fuzzer (vt-parser) with afl-fuzz");

    const ghostty_dep = b.lazyDependency("ghostty", .{
        .simd = false,
    });

    for (fuzz_targets, 0..) |fuzz, i| {
        const target_run_step = b.step(
            b.fmt("run-{s}", .{fuzz.name}),
            b.fmt("Run {s} with afl-fuzz", .{fuzz.name}),
        );

        const lib_mod = b.createModule(.{
            .root_source_file = b.path(fuzz.source),
            .target = target,
            .optimize = optimize,
        });
        if (ghostty_dep) |dep| {
            lib_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        }

        const lib = b.addLibrary(.{
            .name = fuzz.name,
            .root_module = lib_mod,
        });
        lib.root_module.stack_check = false;
        lib.root_module.fuzz = true;

        const exe = afl.addInstrumentedExe(b, lib);

        const run = afl.addFuzzerRun(b, exe, b.path(fuzz.corpus), b.path(b.fmt("afl-out/{s}", .{fuzz.name})));

        b.installArtifact(lib);
        const exe_install = b.addInstallBinFile(exe, fuzz.name);
        b.getInstallStep().dependOn(&exe_install.step);

        target_run_step.dependOn(&run.step);

        // Default `zig build run` runs the first target (vt-parser)
        if (i == 0) {
            run_step.dependOn(&run.step);
        }
    }
}
