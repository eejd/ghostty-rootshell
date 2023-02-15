//! A zig builder step that runs "libtool" against a list of libraries
//! in order to create a single combined static library.
const LibtoolStep = @This();

const std = @import("std");
const Step = std.build.Step;
const FileSource = std.build.FileSource;
const GeneratedFile = std.build.GeneratedFile;

pub const Options = struct {
    /// The name of this step.
    name: []const u8,

    /// The filename (not the path) of the file to create. This will
    /// be placed in a unique hashed directory. Use out_path to access.
    out_name: []const u8,

    /// Library files (.a) to combine.
    sources: []FileSource,
};

step: Step,
builder: *std.Build,

/// Resulting binary
out_path: GeneratedFile,

/// See Options
name: []const u8,
out_name: []const u8,
sources: []FileSource,

pub fn create(builder: *std.Build, opts: Options) *LibtoolStep {
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
    const output_path = try self.builder.cache_root.join(
        self.builder.allocator,
        &.{self.out_name},
    );

    // We use a RunStep here to ease our configuration.
    {
        const run = std.build.RunStep.create(self.builder, self.builder.fmt(
            "libtool {s}",
            .{self.name},
        ));
        run.condition = .always;
        run.addArgs(&.{ "libtool", "-static", "-o", output_path });
        for (self.sources) |source| {
            run.addArg(source.getPath(self.builder));
        }
        try run.step.make();
    }

    self.out_path.path = output_path;
}
