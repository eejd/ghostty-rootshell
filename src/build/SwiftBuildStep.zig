//! A zig builder step that runs "swift build" in the context of
//! a Swift project managed with SwiftPM. This is primarily meant to build
//! executables currently since that is what we build.
const SwiftBuildStep = @This();

const std = @import("std");
const Step = std.build.Step;
const GeneratedFile = std.build.GeneratedFile;

pub const Options = struct {
    /// The product name. This is required to determine the output path
    /// as well.
    product: []const u8,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,

    /// Directory where Package.swift is
    cwd: ?std.build.FileSource = null,

    /// Configuration to build the swift package with. This will default
    /// to "debug" for debug modes and "release" for all other Zig build
    /// modes.
    configuration: ?[]const u8 = null,
};

step: Step,
builder: *std.build.Builder,

/// The generated binary.
bin_path: GeneratedFile,

/// See Options
product: []const u8,
target: std.zig.CrossTarget,
optimize: std.builtin.Mode,
cwd: ?std.build.FileSource = null,
configuration: ?[]const u8 = null,

pub fn create(builder: *std.build.Builder, opts: Options) *SwiftBuildStep {
    const self = builder.allocator.create(SwiftBuildStep) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.custom, "swift build", builder.allocator, make),
        .builder = builder,
        .bin_path = .{ .step = &self.step },
        .product = opts.product,
        .target = opts.target,
        .optimize = opts.optimize,
        .cwd = opts.cwd,
        .configuration = opts.configuration,
    };
    return self;
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(SwiftBuildStep, "step", step);

    const configuration = self.configuration orelse switch (self.optimize) {
        .Debug => "debug",
        else => "release",
    };

    const arch = switch (self.target.getCpuArch()) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => return error.UnsupportedSwiftArch,
    };

    // We use a RunStep here to ease our configuration.
    const run = std.build.RunStep.create(self.builder, "run swift build");
    run.cwd = if (self.cwd) |cwd| cwd.getPath(self.builder) else null;
    run.addArgs(&.{
        "swift",     "build",
        "--product", self.product,
        "-c",        configuration,
        "--arch",    arch,
    });
    try run.step.make();

    // Determine our generated path
    self.bin_path.path = self.builder.fmt(
        "{s}/.build/{s}-apple-macosx/{s}/{s}",
        .{
            run.cwd orelse ".",
            arch,
            configuration,
            self.product,
        },
    );
}
