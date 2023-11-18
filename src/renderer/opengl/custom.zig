const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

/// The "INDEX" is the index into the global GL state and the
/// "BINDING" is the binding location in the shader.
const UNIFORM_INDEX: gl.c.GLuint = 0;
const UNIFORM_BINDING: gl.c.GLuint = 0;

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

/// The state associated with custom shaders.
pub const State = struct {
    /// The uniform data
    uniforms: Uniforms,

    /// The OpenGL buffers
    ubo: gl.Buffer,
    vao: gl.VertexArray,
    ebo: gl.Buffer,

    /// The set of programs for the custom shaders.
    programs: []const Program,

    /// The last time the frame was drawn. This is used to update
    /// the time uniform.
    last_frame_time: std.time.Instant,

    pub fn init(
        alloc: Allocator,
        srcs: []const [:0]const u8,
    ) !State {
        // Create our programs
        var programs = std.ArrayList(Program).init(alloc);
        defer programs.deinit();
        errdefer for (programs.items) |p| p.deinit();
        for (srcs) |src| {
            try programs.append(try Program.init(src));
        }

        // Create our uniform buffer that is shared across all
        // custom shaders
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
            .programs = try programs.toOwnedSlice(),
            .uniforms = .{},
            .ubo = ubo,
            .vao = vao,
            .ebo = ebo,
            .last_frame_time = try std.time.Instant.now(),
        };
    }

    pub fn deinit(self: *const State, alloc: Allocator) void {
        for (self.programs) |p| p.deinit();
        alloc.free(self.programs);
        self.ubo.destroy();
        self.ebo.destroy();
        self.vao.destroy();
    }

    /// Call this prior to drawing a frame to update the time
    /// and synchronize the uniforms. This synchronizes uniforms
    /// so you should make changes to uniforms prior to calling
    /// this.
    pub fn newFrame(self: *State) !void {
        // Update our frame time
        const now = std.time.Instant.now() catch self.last_frame_time;
        const since_ns: f32 = @floatFromInt(now.since(self.last_frame_time));
        self.uniforms.time = since_ns / std.time.ns_per_s;
        self.uniforms.time_delta = since_ns / std.time.ns_per_s;

        // Sync our uniform changes
        var ubobind = try self.ubo.bind(.uniform);
        defer ubobind.unbind();
        try ubobind.setData(self.uniforms, .static_draw);
    }

    pub fn bind(self: *const State) !Binding {
        // Move our uniform buffer into proper global index. Note that
        // in theory we can do this globally once and never worry about
        // it again. I don't think we're high-performance enough at all
        // to worry about that and this makes it so you can just move
        // around CustomProgram usage without worrying about clobbering
        // the global state.
        try self.ubo.bindBase(.uniform, UNIFORM_INDEX);

        const vao = try self.vao.bind();
        errdefer vao.unbind();

        const ebo = try self.ebo.bind(.element_array);
        errdefer ebo.unbind();

        return .{
            .vao = vao,
            .ebo = ebo,
        };
    }

    pub const Binding = struct {
        vao: gl.VertexArray.Binding,
        ebo: gl.Buffer.Binding,

        pub fn unbind(self: Binding) void {
            self.ebo.unbind();
            self.vao.unbind();
        }
    };
};

/// A single OpenGL program (combined shaders) for custom shaders.
pub const Program = struct {
    program: gl.Program,

    pub fn init(src: [:0]const u8) !Program {
        const program = try gl.Program.createVF(
            @embedFile("../shaders/custom.v.glsl"),
            src,
            //@embedFile("../shaders/temp.f.glsl"),
        );
        errdefer program.destroy();

        // Map our uniform buffer to the global GL state
        try program.uniformBlockBinding(UNIFORM_INDEX, UNIFORM_BINDING);

        return .{ .program = program };
    }

    pub fn deinit(self: *const Program) void {
        self.program.destroy();
    }

    pub fn bind(self: *const Program) !Binding {
        const program = try self.program.use();
        errdefer program.unbind();

        return .{
            .program = program,
        };
    }

    pub const Binding = struct {
        program: gl.Program.Binding,

        pub fn unbind(self: Binding) void {
            self.program.unbind();
        }
    };
};
