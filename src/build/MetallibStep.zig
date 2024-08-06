/// A zig build step that compiles a set of ".metal" files into a
/// ".metallib" file.
const MetallibStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// The name of the xcframework to create.
    name: []const u8,

    /// The Metal source files.
    sources: []const LazyPath,
};

step: *Step,
output: LazyPath,

pub fn create(b: *std.Build, opts: Options) *MetallibStep {
    const self = b.allocator.create(MetallibStep) catch @panic("OOM");

    const run_ir = RunStep.create(
        b,
        b.fmt("metal {s}", .{opts.name}),
    );
    run_ir.addArgs(&.{ "xcrun", "-sdk", "macosx", "metal", "-o" });
    const output_ir = run_ir.addOutputFileArg(b.fmt("{s}.ir", .{opts.name}));
    run_ir.addArgs(&.{"-c"});
    for (opts.sources) |source| run_ir.addFileArg(source);

    const run_lib = RunStep.create(
        b,
        b.fmt("metallib {s}", .{opts.name}),
    );
    run_lib.addArgs(&.{ "xcrun", "-sdk", "macosx", "metallib", "-o" });
    const output_lib = run_lib.addOutputFileArg(b.fmt("{s}.metallib", .{opts.name}));
    run_lib.addFileArg(output_ir);
    run_lib.step.dependOn(&run_ir.step);

    self.* = .{
        .step = &run_lib.step,
        .output = output_lib,
    };

    return self;
}
