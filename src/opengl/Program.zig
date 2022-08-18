const Program = @This();

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.opengl);

const c = @import("c.zig");
const Shader = @import("Shader.zig");
const errors = @import("errors.zig");

id: c.GLuint,

const Binding = struct {
    pub inline fn unbind(_: Binding) void {
        c.glUseProgram(0);
    }
};

pub inline fn create() !Program {
    const id = c.glCreateProgram();
    if (id == 0) try errors.mustError();

    log.debug("program created id={}", .{id});
    return Program{ .id = id };
}

/// Create a program from a vertex and fragment shader source. This will
/// compile and link the vertex and fragment shader.
pub inline fn createVF(vsrc: [:0]const u8, fsrc: [:0]const u8) !Program {
    const vs = try Shader.create(c.GL_VERTEX_SHADER);
    try vs.setSourceAndCompile(vsrc);
    defer vs.destroy();

    const fs = try Shader.create(c.GL_FRAGMENT_SHADER);
    try fs.setSourceAndCompile(fsrc);
    defer fs.destroy();

    const p = try create();
    try p.attachShader(vs);
    try p.attachShader(fs);
    try p.link();

    return p;
}

pub inline fn attachShader(p: Program, s: Shader) !void {
    c.glAttachShader(p.id, s.id);
    try errors.getError();
}

pub inline fn link(p: Program) !void {
    c.glLinkProgram(p.id);

    // Check if linking succeeded
    var success: c_int = undefined;
    c.glGetProgramiv(p.id, c.GL_LINK_STATUS, &success);
    if (success == c.GL_TRUE) {
        log.debug("program linked id={}", .{p.id});
        return;
    }

    log.err("program link failure id={} message={s}", .{
        p.id,
        std.mem.sliceTo(&p.getInfoLog(), 0),
    });
    return error.CompileFailed;
}

pub inline fn use(p: Program) !Binding {
    c.glUseProgram(p.id);
    return Binding{};
}

/// Requires the program is currently in use.
pub inline fn setUniform(p: Program, n: [:0]const u8, value: anytype) !void {
    const loc = c.glGetUniformLocation(p.id, n);
    if (loc < 0) {
        return error.UniformNameInvalid;
    }
    try errors.getError();

    // Perform the correct call depending on the type of the value.
    switch (@TypeOf(value)) {
        comptime_int => c.glUniform1i(loc, value),
        f32 => c.glUniform1f(loc, value),
        @Vector(2, f32) => c.glUniform2f(loc, value[0], value[1]),
        @Vector(3, f32) => c.glUniform3f(loc, value[0], value[1], value[2]),
        @Vector(4, f32) => c.glUniform4f(loc, value[0], value[1], value[2], value[3]),
        [4]@Vector(4, f32) => c.glUniformMatrix4fv(
            loc,
            1,
            c.GL_FALSE,
            @ptrCast([*c]const f32, &value),
        ),
        else => unreachable,
    }
    try errors.getError();
}

/// getInfoLog returns the info log for this program. This attempts to
/// keep the log fully stack allocated and is therefore limited to a max
/// amount of elements.
//
// NOTE(mitchellh): we can add a dynamic version that uses an allocator
// if we ever need it.
pub inline fn getInfoLog(s: Program) [512]u8 {
    var msg: [512]u8 = undefined;
    c.glGetProgramInfoLog(s.id, msg.len, null, &msg);
    return msg;
}

pub inline fn destroy(p: Program) void {
    assert(p.id != 0);
    c.glDeleteProgram(p.id);
    log.debug("program destroyed id={}", .{p.id});
}
