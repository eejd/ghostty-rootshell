//! A zig builder step that runs "lipo" on two binaries to create
//! a universal binary.
const LibtoolStep = @This();

const std = @import("std");
const Step = std.build.Step;
const FileSource = std.build.FileSource;
const GeneratedFile = std.build.GeneratedFile;

pub const Options = struct {
    /// The name of the xcframework to create.
    name: []const u8,

    /// The filename (not the path) of the file to create.
    out_name: []const u8,

    /// Library file (dylib, a) to package.
    sources: []FileSource,
};

step: Step,
builder: *std.build.Builder,

/// Resulting binary
out_path: GeneratedFile,

/// See Options
name: []const u8,
out_name: []const u8,
sources: []FileSource,

pub fn create(builder: *std.build.Builder, opts: Options) *LibtoolStep {
    const self = builder.allocator.create(LibtoolStep) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.custom, builder.fmt("lipo {s}", .{opts.name}), builder.allocator, make),
        .builder = builder,
        .name = opts.name,
        .out_path = .{ .step = &self.step },
        .out_name = opts.out_name,
        .sources = opts.sources,
    };
    return self;
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(LibtoolStep, "step", step);

    // TODO: use the zig cache system when it is in the stdlib
    // https://github.com/ziglang/zig/pull/14571
    const output_path = self.builder.pathJoin(&.{
        self.builder.cache_root, self.out_name,
    });

    // We use a RunStep here to ease our configuration.
    {
        const run = std.build.RunStep.create(self.builder, self.builder.fmt(
            "libtool {s}",
            .{self.name},
        ));
        run.addArgs(&.{ "libtool", "-static", "-o", output_path });
        for (self.sources) |source| {
            run.addArg(source.getPath(self.builder));
        }
        try run.step.make();
    }

    self.out_path.path = output_path;
}
