/// The OpenGL program for custom shaders.
const CustomProgram = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

/// The "INDEX" is the index into the global GL state and the
/// "BINDING" is the binding location in the shader.
const UNIFORM_INDEX: gl.c.GLuint = 0;
const UNIFORM_BINDING: gl.c.GLuint = 0;

/// The uniform state. Whenever this is modified this should be
/// synced to the buffer. The draw/bind calls don't automatically
/// sync this so this should be done whenever the state is modified.
uniforms: Uniforms = .{},

/// The actual shader program.
program: gl.Program,

/// The uniform buffer that is updated with our uniform data.
ubo: gl.Buffer,

/// This VAO is used for all custom shaders. It contains a single quad
/// by using an EBO. The vertex ID (gl_VertexID) can be used to determine the
/// position of the vertex.
vao: gl.VertexArray,
ebo: gl.Buffer,

pub const Uniforms = extern struct {
    resolution: [3]f32 align(16) = .{ 0, 0, 0 },
    time: f32 align(4) = 1,
    time_delta: f32 align(4) = 1,
    frame_rate: f32 align(4) = 1,
    frame: i32 align(4) = 1,
    channel_time: [4][4]f32 align(16) = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
    channel_resolution: [4][4]f32 align(16) = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
    mouse: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    date: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    sample_rate: f32 align(4) = 1,
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
        //@embedFile("../shaders/temp.f.glsl"),
    );
    errdefer program.destroy();

    // Map our uniform buffer to the global GL state
    try program.uniformBlockBinding(UNIFORM_INDEX, UNIFORM_BINDING);

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
        .ubo = ubo,
        .vao = vao,
        .ebo = ebo,
    };
}

pub fn deinit(self: CustomProgram) void {
    self.ebo.destroy();
    self.vao.destroy();
    self.program.destroy();
}

pub fn syncUniforms(self: CustomProgram) !void {
    var ubobind = try self.ubo.bind(.uniform);
    defer ubobind.unbind();
    try ubobind.setData(self.uniforms, .static_draw);
}

pub fn bind(self: CustomProgram) !Binding {
    // Move our uniform buffer into proper global index. Note that
    // in theory we can do this globally once and never worry about
    // it again. I don't think we're high-performance enough at all
    // to worry about that and this makes it so you can just move
    // around CustomProgram usage without worrying about clobbering
    // the global state.
    try self.ubo.bindBase(.uniform, UNIFORM_INDEX);

    const program = try self.program.use();
    errdefer program.unbind();

    const vao = try self.vao.bind();
    errdefer vao.unbind();

    const ebo = try self.ebo.bind(.element_array);
    errdefer ebo.unbind();

    return .{
        .program = program,
        .vao = vao,
        .ebo = ebo,
    };
}

pub const Binding = struct {
    program: gl.Program.Binding,
    vao: gl.VertexArray.Binding,
    ebo: gl.Buffer.Binding,

    pub fn unbind(self: Binding) void {
        self.ebo.unbind();
        self.vao.unbind();
        self.program.unbind();
    }
};
