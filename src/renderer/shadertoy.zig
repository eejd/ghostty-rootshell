const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const glslang = @import("glslang");

/// Convert a ShaderToy shader into valid GLSL.
///
/// ShaderToy shaders aren't full shaders, they're just implementing a
/// mainImage function and don't define any of the uniforms. This function
/// will convert the ShaderToy shader into a valid GLSL shader that can be
/// compiled and linked.
pub fn glslFromShader(writer: anytype, src: []const u8) !void {
    const prefix = @embedFile("shaders/shadertoy_prefix.glsl");
    try writer.writeAll(prefix);
    try writer.writeAll("\n\n");
    try writer.writeAll(src);
}

/// Convert a GLSL shader into SPIR-V assembly.
pub fn spirvFromGlsl(
    writer: anytype,
    errlog: ?*SpirvLog,
    src: [:0]const u8,
) !void {
    // So we can run unit tests without fear.
    if (builtin.is_test) try glslang.testing.ensureInit();

    const c = glslang.c;
    const input: c.glslang_input_t = .{
        .language = c.GLSLANG_SOURCE_GLSL,
        .stage = c.GLSLANG_STAGE_FRAGMENT,
        .client = c.GLSLANG_CLIENT_VULKAN,
        .client_version = c.GLSLANG_TARGET_VULKAN_1_2,
        .target_language = c.GLSLANG_TARGET_SPV,
        .target_language_version = c.GLSLANG_TARGET_SPV_1_5,
        .code = src.ptr,
        .default_version = 100,
        .default_profile = c.GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = 0,
        .forward_compatible = 0,
        .messages = c.GLSLANG_MSG_DEFAULT_BIT,
        .resource = c.glslang_default_resource(),
    };

    const shader = try glslang.Shader.create(&input);
    defer shader.delete();

    shader.preprocess(&input) catch |err| {
        if (errlog) |ptr| ptr.fromShader(shader) catch {};
        return err;
    };
    shader.parse(&input) catch |err| {
        if (errlog) |ptr| ptr.fromShader(shader) catch {};
        return err;
    };

    const program = try glslang.Program.create();
    defer program.delete();
    program.addShader(shader);
    program.link(
        c.GLSLANG_MSG_SPV_RULES_BIT |
            c.GLSLANG_MSG_VULKAN_RULES_BIT,
    ) catch |err| {
        if (errlog) |ptr| ptr.fromProgram(program) catch {};
        return err;
    };
    program.spirvGenerate(c.GLSLANG_STAGE_FRAGMENT);
    const size = program.spirvGetSize();
    const ptr = try program.spirvGetPtr();
    try writer.writeAll(ptr[0..size]);
}

/// Retrieve errors from spirv compilation.
pub const SpirvLog = struct {
    alloc: Allocator,
    info: [:0]const u8 = "",
    debug: [:0]const u8 = "",

    pub fn deinit(self: *const SpirvLog) void {
        if (self.info.len > 0) self.alloc.free(self.info);
        if (self.debug.len > 0) self.alloc.free(self.debug);
    }

    fn fromShader(self: *SpirvLog, shader: *glslang.Shader) !void {
        const info = try shader.getInfoLog();
        const debug = try shader.getDebugInfoLog();
        self.info = "";
        self.debug = "";
        if (info.len > 0) self.info = try self.alloc.dupeZ(u8, info);
        if (debug.len > 0) self.debug = try self.alloc.dupeZ(u8, debug);
    }

    fn fromProgram(self: *SpirvLog, program: *glslang.Program) !void {
        const info = try program.getInfoLog();
        const debug = try program.getDebugInfoLog();
        self.info = "";
        self.debug = "";
        if (info.len > 0) self.info = try self.alloc.dupeZ(u8, info);
        if (debug.len > 0) self.debug = try self.alloc.dupeZ(u8, debug);
    }
};

/// Convert ShaderToy shader to null-terminated glsl for testing.
fn testGlslZ(alloc: Allocator, src: []const u8) ![:0]const u8 {
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    try glslFromShader(list.writer(), src);
    return try list.toOwnedSliceSentinel(0);
}

test "spirv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: [4096]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    const writer = buf_stream.writer();
    try spirvFromGlsl(writer, null, src);
}

test "spirv invalid" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_invalid);
    defer alloc.free(src);

    var buf: [4096]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    const writer = buf_stream.writer();

    var errlog: SpirvLog = .{ .alloc = alloc };
    defer errlog.deinit();
    try testing.expectError(error.GlslangFailed, spirvFromGlsl(writer, &errlog, src));
    try testing.expect(errlog.info.len > 0);
}

const test_crt = @embedFile("shaders/test_shadertoy_crt.glsl");
const test_invalid = @embedFile("shaders/test_shadertoy_invalid.glsl");
