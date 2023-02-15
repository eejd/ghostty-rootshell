//! A zig builder step that runs "swift build" in the context of
//! a Swift project managed with SwiftPM. This is primarily meant to build
//! executables currently since that is what we build.
const XCFrameworkStep = @This();

const std = @import("std");
const Step = std.build.Step;
const GeneratedFile = std.build.GeneratedFile;

pub const Options = struct {
    /// The name of the xcframework to create.
    name: []const u8,

    /// The path to write the framework
    out_path: []const u8,

    /// Library file (dylib, a) to package.
    library: std.build.FileSource,

    /// Path to a directory with the headers.
    headers: std.build.FileSource,
};

step: Step,
builder: *std.build.Builder,

/// See Options
name: []const u8,
out_path: []const u8,
library: std.build.FileSource,
headers: std.build.FileSource,

pub fn create(builder: *std.build.Builder, opts: Options) *XCFrameworkStep {
    const self = builder.allocator.create(XCFrameworkStep) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.custom, builder.fmt(
            "xcframework {s}",
            .{opts.name},
        ), builder.allocator, make),
        .builder = builder,
        .name = opts.name,
        .out_path = opts.out_path,
        .library = opts.library,
        .headers = opts.headers,
    };
    return self;
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(XCFrameworkStep, "step", step);

    // TODO: use the zig cache system when it is in the stdlib
    // https://github.com/ziglang/zig/pull/14571
    const output_path = self.out_path;

    // We use a RunStep here to ease our configuration.
    {
        const run = std.build.RunStep.create(self.builder, self.builder.fmt(
            "xcframework delete {s}",
            .{self.name},
        ));
        run.condition = .always;
        run.addArgs(&.{ "rm", "-rf", output_path });
        try run.step.make();
    }
    {
        const run = std.build.RunStep.create(self.builder, self.builder.fmt(
            "xcframework {s}",
            .{self.name},
        ));
        run.condition = .always;
        run.addArgs(&.{
            "xcodebuild", "-create-xcframework",
            "-library",   self.library.getPath(self.builder),
            "-headers",   self.headers.getPath(self.builder),
            "-output",    output_path,
        });
        try run.step.make();
    }
}
