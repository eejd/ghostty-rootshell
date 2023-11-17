/// The OpenGL program for custom shaders.
const CustomProgram = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

program: gl.Program,

/// This VAO is used for all custom shaders. It contains a single quad
/// by using an EBO. The vertex ID (gl_VertexID) can be used to determine the
/// position of the vertex.
vao: gl.VertexArray,
ebo: gl.Buffer,

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
    _ = src;
    const program = try gl.Program.createVF(
        @embedFile("../shaders/custom.v.glsl"),
        //src,
        @embedFile("../shaders/temp.f.glsl"),
    );
    errdefer program.destroy();

    // Create our uniform buffer that is shared across all custom shaders
    const ubo = try gl.Buffer.create();
    errdefer ubo.destroy();
    {
        var ubobind = try ubo.bind(.uniform);
        defer ubobind.unbind();
        try ubobind.setDataNull(Uniforms, .static_draw);
    }

    // Setup our VAO for the custom shader.
    const vao = try gl.VertexArray.create();
    errdefer vao.destroy();
    const vaobind = try vao.bind();
    defer vaobind.unbind();

    // Element buffer (EBO)
    const ebo = try gl.Buffer.create();
    errdefer ebo.destroy();
    var ebobind = try ebo.bind(.element_array);
    defer ebobind.unbind();
    try ebobind.setData([6]u8{
        0, 1, 3, // Top-left triangle
        1, 2, 3, // Bottom-right triangle
    }, .static_draw);

    return .{
        .program = program,
        .vao = vao,
        .ebo = ebo,
    };
}

pub fn deinit(self: CustomProgram) void {
    self.ebo.destroy();
    self.vao.destroy();
    self.program.destroy();
}
