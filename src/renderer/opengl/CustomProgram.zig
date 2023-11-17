/// The OpenGL program for custom shaders.
const CustomProgram = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

program: gl.Program,

pub const Uniforms = extern struct {
    resolution: [3]f32 align(16),
    time: f32 align(4),
    time_delta: f32 align(4),
    frame_rate: f32 align(4),
    frame: i32 align(4),
    channel_time: [4][4]f32 align(16),
    channel_resolution: [4][4]f32 align(16),
    mouse: [4]f32 align(16),
    date: [4]f32 align(16),
    sample_rate: f32 align(4),
};

pub fn createList(alloc: Allocator, srcs: []const [:0]const u8) ![]const CustomProgram {
    var programs = std.ArrayList(CustomProgram).init(alloc);
    defer programs.deinit();
    errdefer for (programs.items) |program| program.deinit();

    for (srcs) |src| {
        try programs.append(try CustomProgram.init(src));
    }

    return try programs.toOwnedSlice();
}

pub fn init(src: [:0]const u8) !CustomProgram {
    const program = try gl.Program.createVF(
        @embedFile("../shaders/custom.v.glsl"),
        src,
    );
    errdefer program.destroy();

    // Create our uniform buffer that is shared across all custom shaders
    const ubo = try gl.Buffer.create();
    errdefer ubo.destroy();
    var ubobind = try ubo.bind(.uniform);
    defer ubobind.unbind();
    try ubobind.setDataNull(Uniforms, .static_draw);

    return .{
        .program = program,
    };
}

pub fn deinit(self: CustomProgram) void {
    self.program.destroy();
}
