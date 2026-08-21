const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const glslang = @import("glslang");
const spvcross = @import("spirv_cross");
const configpkg = @import("../config.zig");
const compat_file = @import("../lib/compat/file.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.shadertoy);

/// Metadata extracted from shader source during loading.
/// Used to determine animation behavior and optimization strategies.
pub const ShaderMetadata = struct {
    /// Duration of cursor animation in seconds. null = continuous animation required.
    cursor_animation_duration: ?f32,
    /// True if shader uses iTime for continuous full-screen effects (not just cursor).
    is_continuous: bool,
};

/// A loaded shader with its compiled source and metadata.
pub const LoadedShader = struct {
    source: [:0]const u8,
    metadata: ShaderMetadata,
};

/// Analyze shader source to extract animation metadata.
/// This is called on the raw shader source before GLSL conversion.
pub fn analyzeShader(src: []const u8) ShaderMetadata {
    var metadata: ShaderMetadata = .{
        .cursor_animation_duration = null,
        .is_continuous = false,
    };

    // Parse DURATION constant: look for "const float DURATION = X.X;"
    metadata.cursor_animation_duration = findDurationConstant(src);

    // Check if shader uses cursor uniforms (indicates cursor-based animation)
    const uses_cursor = std.mem.indexOf(u8, src, "iCurrentCursor") != null or
        std.mem.indexOf(u8, src, "iPreviousCursor") != null or
        std.mem.indexOf(u8, src, "iTimeCursorChange") != null;

    // Check if shader uses iTime (indicates time-based animation)
    const uses_time = std.mem.indexOf(u8, src, "iTime") != null;

    // A shader is continuous if:
    // - It uses iTime but NOT cursor uniforms (full-screen time effect)
    // - It uses iTime AND cursor uniforms but has no DURATION (or DURATION >= 10s)
    if (uses_time) {
        if (!uses_cursor) {
            // Uses time but not cursor = continuous full-screen effect
            metadata.is_continuous = true;
        } else if (metadata.cursor_animation_duration == null) {
            // Uses both time and cursor but no duration = continuous
            metadata.is_continuous = true;
        } else if (metadata.cursor_animation_duration.? >= 10.0) {
            // Very long duration = treat as continuous
            metadata.is_continuous = true;
        }
    }

    return metadata;
}

/// Parse "const float DURATION = X.X;" from shader source.
/// Returns the duration value in seconds, or null if not found.
fn findDurationConstant(src: []const u8) ?f32 {
    // Search for the DURATION constant pattern
    // Handle variations: "const float DURATION = 0.5;", "const float DURATION=.5;"
    const pattern = "DURATION";
    var pos: usize = 0;

    while (std.mem.indexOfPos(u8, src, pos, pattern)) |idx| {
        pos = idx + pattern.len;

        // Skip whitespace
        while (pos < src.len and (src[pos] == ' ' or src[pos] == '\t')) {
            pos += 1;
        }

        // Expect '='
        if (pos >= src.len or src[pos] != '=') continue;
        pos += 1;

        // Skip whitespace
        while (pos < src.len and (src[pos] == ' ' or src[pos] == '\t')) {
            pos += 1;
        }

        // Parse the float value
        const start = pos;
        var has_digit = false;
        var has_dot = false;

        while (pos < src.len) {
            const c = src[pos];
            if (c >= '0' and c <= '9') {
                has_digit = true;
                pos += 1;
            } else if (c == '.' and !has_dot) {
                has_dot = true;
                pos += 1;
            } else {
                break;
            }
        }

        if (!has_digit) continue;

        // Parse the number
        const num_str = src[start..pos];
        const value = std.fmt.parseFloat(f32, num_str) catch continue;

        // Validate: duration should be positive and reasonable (< 60s)
        if (value > 0.0 and value < 60.0) {
            return value;
        }
    }

    return null;
}

/// The uniform struct used for shadertoy shaders.
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
    current_cursor: [4]f32 align(16),
    previous_cursor: [4]f32 align(16),
    current_cursor_color: [4]f32 align(16),
    previous_cursor_color: [4]f32 align(16),
    current_cursor_style: i32 align(4),
    previous_cursor_style: i32 align(4),
    cursor_visible: i32 align(4),
    cursor_change_time: f32 align(4),
    time_focus: f32 align(4),
    focus: i32 align(4),
    palette: [256][4]f32 align(16),
    background_color: [4]f32 align(16),
    foreground_color: [4]f32 align(16),
    cursor_color: [4]f32 align(16),
    cursor_text: [4]f32 align(16),
    selection_background_color: [4]f32 align(16),
    selection_foreground_color: [4]f32 align(16),
};

/// The target to load shaders for.
pub const Target = enum { glsl, msl };

/// Load a set of shaders from files with metadata and convert them to the target
/// format. The shader order is preserved. Returns both compiled shaders and their metadata.
pub fn loadFromFilesWithMetadata(
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    target: Target,
) ![]const LoadedShader {
    var list: std.ArrayList(LoadedShader) = .empty;
    defer list.deinit(alloc_gpa);
    errdefer for (list.items) |shader| alloc_gpa.free(shader.source);

    for (paths.value.items) |item| {
        const path, const optional = switch (item) {
            .optional => |path| .{ path, true },
            .required => |path| .{ path, false },
        };

        const loaded = loadFromFileWithMetadata(alloc_gpa, path, target) catch |err| {
            if (err == error.FileNotFound and optional) {
                continue;
            }

            return err;
        };
        log.info("loaded custom shader path={s} duration={?} continuous={}", .{
            path,
            loaded.metadata.cursor_animation_duration,
            loaded.metadata.is_continuous,
        });
        try list.append(alloc_gpa, loaded);
    }

    return try list.toOwnedSlice(alloc_gpa);
}

/// Load a single shader from a file with metadata and convert it to the target language.
pub fn loadFromFileWithMetadata(
    alloc_gpa: Allocator,
    path: []const u8,
    target: Target,
) !LoadedShader {
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read it all into memory -- we don't expect shaders to be large.
    const src = src: {
        // Load the shader file
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(global.io(), path, .{});
        defer file.close(global.io());

        break :src try compat_file.readToEndAlloc(
            file,
            alloc,
            4 * 1024 * 1024, // 4MB
        );
    };

    // Analyze shader source BEFORE conversion to extract metadata
    const metadata = analyzeShader(src);

    // Convert to full GLSL
    const glsl: [:0]const u8 = glsl: {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        try glslFromShader(&stream.writer, src);
        try stream.writer.writeByte(0);
        break :glsl stream.written()[0 .. stream.written().len - 1 :0];
    };

    // Convert to SPIR-V
    const spirv: []const u8 = spirv: {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        var errlog: SpirvLog = .{ .alloc = alloc };
        defer errlog.deinit();
        spirvFromGlsl(&stream.writer, &errlog, glsl) catch |err| {
            if (errlog.info.len > 0 or errlog.debug.len > 0) {
                log.warn("spirv error path={s} info={s} debug={s}", .{
                    path,
                    errlog.info,
                    errlog.debug,
                });
            }

            return err;
        };

        // SpirV pointer must be aligned to 4 bytes since we expect
        // a slice of words.
        var list: std.ArrayListAligned(u8, .of(u32)) = .empty;
        try list.appendSlice(alloc, stream.written());
        break :spirv list.items;
    };

    // Convert to target format
    const compiled = switch (target) {
        .glsl => try glslFromSpv(alloc_gpa, spirv),
        .msl => try mslFromSpv(alloc_gpa, spirv),
    };

    return .{
        .source = compiled,
        .metadata = metadata,
    };
}

/// Load a set of shaders from files and convert them to the target
/// format. The shader order is preserved.
pub fn loadFromFiles(
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    target: Target,
) ![]const [:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;
    defer list.deinit(alloc_gpa);
    errdefer for (list.items) |shader| alloc_gpa.free(shader);

    for (paths.value.items) |item| {
        const path, const optional = switch (item) {
            .optional => |path| .{ path, true },
            .required => |path| .{ path, false },
        };

        const shader = loadFromFile(alloc_gpa, path, target) catch |err| {
            if (err == error.FileNotFound and optional) {
                continue;
            }

            return err;
        };
        log.info("loaded custom shader path={s}", .{path});
        try list.append(alloc_gpa, shader);
    }

    return try list.toOwnedSlice(alloc_gpa);
}

/// Load a single shader from a file and convert it to the target language
/// ready to be used with renderers.
pub fn loadFromFile(
    alloc_gpa: Allocator,
    path: []const u8,
    target: Target,
) ![:0]const u8 {
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read it all into memory -- we don't expect shaders to be large.
    const src = src: {
        // Load the shader file
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(global.io(), path, .{});
        defer file.close(global.io());
        break :src try compat_file.readToEndAlloc(
            file,
            alloc,
            4 * 1024 * 1024, // 4MB
        );
    };

    // Convert to full GLSL
    const glsl: [:0]const u8 = glsl: {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        try glslFromShader(&stream.writer, src);
        try stream.writer.writeByte(0);
        break :glsl stream.written()[0 .. stream.written().len - 1 :0];
    };

    // Convert to SPIR-V
    const spirv: []const u8 = spirv: {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        var errlog: SpirvLog = .{ .alloc = alloc };
        defer errlog.deinit();
        spirvFromGlsl(&stream.writer, &errlog, glsl) catch |err| {
            if (errlog.info.len > 0 or errlog.debug.len > 0) {
                log.warn("spirv error path={s} info={s} debug={s}", .{
                    path,
                    errlog.info,
                    errlog.debug,
                });
            }

            return err;
        };

        // SpirV pointer must be aligned to 4 bytes since we expect
        // a slice of words.
        var list: std.ArrayListAligned(u8, .of(u32)) = .empty;
        try list.appendSlice(alloc, stream.written());
        break :spirv list.items;
    };

    // Convert to MSL
    return switch (target) {
        // Important: using the alloc_gpa here on purpose because this
        // is the final result that will be returned to the caller.
        .glsl => try glslFromSpv(alloc_gpa, spirv),
        .msl => try mslFromSpv(alloc_gpa, spirv),
    };
}

/// Convert a ShaderToy shader into valid GLSL.
///
/// ShaderToy shaders aren't full shaders, they're just implementing a
/// mainImage function and don't define any of the uniforms. This function
/// will convert the ShaderToy shader into a valid GLSL shader that can be
/// compiled and linked.
pub fn glslFromShader(writer: *std.Io.Writer, src: []const u8) !void {
    const prefix = @embedFile("shaders/shadertoy_prefix.glsl");
    try writer.writeAll(prefix);
    try writer.writeAll("\n\n");
    try writer.writeAll(src);
}

/// Convert a GLSL shader into SPIR-V assembly.
pub fn spirvFromGlsl(
    writer: *std.Io.Writer,
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
    const ptr_u8: [*]u8 = @ptrCast(ptr);
    const slice_u8: []u8 = ptr_u8[0 .. size * 4];
    try writer.writeAll(slice_u8);
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

/// Convert SPIR-V binary to MSL.
pub fn mslFromSpv(alloc: Allocator, spv: []const u8) ![:0]const u8 {
    const c = spvcross.c;
    return try spvCross(alloc, spvcross.c.SPVC_BACKEND_MSL, spv, (struct {
        fn setOptions(options: c.spvc_compiler_options) error{SpvcFailed}!void {
            // We enable decoration binding, because we need this
            // to properly locate the uniform block to index 1.
            if (c.spvc_compiler_options_set_bool(
                options,
                c.SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING,
                c.SPVC_TRUE,
            ) != c.SPVC_SUCCESS) {
                return error.SpvcFailed;
            }
        }
    }).setOptions);
}

/// Convert SPIR-V binary to GLSL.
pub fn glslFromSpv(alloc: Allocator, spv: []const u8) ![:0]const u8 {
    const GLSL_VERSION = 430;

    const c = spvcross.c;
    return try spvCross(alloc, c.SPVC_BACKEND_GLSL, spv, (struct {
        fn setOptions(options: c.spvc_compiler_options) error{SpvcFailed}!void {
            if (c.spvc_compiler_options_set_uint(
                options,
                c.SPVC_COMPILER_OPTION_GLSL_VERSION,
                GLSL_VERSION,
            ) != c.SPVC_SUCCESS) {
                return error.SpvcFailed;
            }
        }
    }).setOptions);
}

fn spvCross(
    alloc: Allocator,
    backend: spvcross.c.spvc_backend,
    spv: []const u8,
    comptime optionsFn_: ?*const fn (c: spvcross.c.spvc_compiler_options) error{SpvcFailed}!void,
) ![:0]const u8 {
    // Spir-V is always a multiple of 4 because it is written as a series of words
    if (@mod(spv.len, 4) != 0) return error.SpirvInvalid;

    // Compiler context
    const c = spvcross.c;
    var ctx: c.spvc_context = undefined;
    if (c.spvc_context_create(&ctx) != c.SPVC_SUCCESS) return error.SpvcFailed;
    defer c.spvc_context_destroy(ctx);

    // It would be better to get this out into an output parameter to
    // show users but for now we can just log it.
    c.spvc_context_set_error_callback(ctx, @ptrCast(&(struct {
        fn callback(_: ?*anyopaque, msg_ptr: [*c]const u8) callconv(.c) void {
            const msg = std.mem.sliceTo(msg_ptr, 0);
            std.log.warn("spirv-cross error message={s}", .{msg});
        }
    }).callback), null);

    // Parse the Spir-V binary to an IR
    var ir: c.spvc_parsed_ir = undefined;
    if (c.spvc_context_parse_spirv(
        ctx,
        @ptrCast(@alignCast(spv.ptr)),
        spv.len / 4,
        &ir,
    ) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    // Build our compiler to GLSL
    var compiler: c.spvc_compiler = undefined;
    if (c.spvc_context_create_compiler(
        ctx,
        backend,
        ir,
        c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
        &compiler,
    ) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    // Setup our options if we have any
    if (optionsFn_) |optionsFn| {
        var options: c.spvc_compiler_options = undefined;
        if (c.spvc_compiler_create_compiler_options(compiler, &options) != c.SPVC_SUCCESS) {
            return error.SpvcFailed;
        }

        try optionsFn(options);

        if (c.spvc_compiler_install_compiler_options(compiler, options) != c.SPVC_SUCCESS) {
            return error.SpvcFailed;
        }
    }

    // Compile the resulting string. This string pointer is owned by the
    // context so we don't need to free it.
    var result: [*:0]const u8 = undefined;
    if (c.spvc_compiler_compile(compiler, @ptrCast(&result)) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    return try alloc.dupeZ(u8, std.mem.sliceTo(result, 0));
}

/// Convert ShaderToy shader to null-terminated glsl for testing.
fn testGlslZ(alloc: Allocator, src: []const u8) ![:0]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try glslFromShader(&buf.writer, src);
    return try buf.toOwnedSliceSentinel(0);
}

test "spirv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: [4096 * 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try spirvFromGlsl(&writer, null, src);
}

test "spirv invalid" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_invalid);
    defer alloc.free(src);

    var buf: [4096 * 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var errlog: SpirvLog = .{ .alloc = alloc };
    defer errlog.deinit();
    try testing.expectError(error.GlslangFailed, spirvFromGlsl(&writer, &errlog, src));
    try testing.expect(errlog.info.len > 0);
}

test "shadertoy to msl" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try spirvFromGlsl(&buf.writer, null, src);

    // TODO: Replace this with an aligned version of Writer.Allocating
    var spvlist: std.ArrayListAligned(u8, .of(u32)) = .empty;
    defer spvlist.deinit(alloc);
    try spvlist.appendSlice(alloc, buf.written());

    const msl = try mslFromSpv(alloc, spvlist.items);
    defer alloc.free(msl);
}

test "shadertoy to glsl" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try spirvFromGlsl(&buf.writer, null, src);

    // TODO: Replace this with an aligned version of Writer.Allocating
    var spvlist: std.ArrayListAligned(u8, .of(u32)) = .empty;
    defer spvlist.deinit(alloc);
    try spvlist.appendSlice(alloc, buf.written());

    const glsl = try glslFromSpv(alloc, spvlist.items);
    defer alloc.free(glsl);

    // log.warn("glsl={s}", .{glsl});
}

const test_crt = @embedFile("shaders/test_shadertoy_crt.glsl");
const test_invalid = @embedFile("shaders/test_shadertoy_invalid.glsl");
const test_focus = @embedFile("shaders/test_shadertoy_focus.glsl");

test "analyzeShader cursor with duration" {
    const testing = std.testing;

    // Shader with DURATION constant and cursor uniforms
    const src =
        \\const float DURATION = 0.5;
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec4 cursor = iCurrentCursor;
        \\    vec4 prev = iPreviousCursor;
        \\    fragColor = vec4(1.0);
        \\}
    ;

    const metadata = analyzeShader(src);
    try testing.expectEqual(@as(?f32, 0.5), metadata.cursor_animation_duration);
    try testing.expectEqual(false, metadata.is_continuous);
}

test "analyzeShader continuous time-based" {
    const testing = std.testing;

    // Shader with iTime but no cursor uniforms (continuous)
    const src =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    float t = iTime;
        \\    fragColor = vec4(sin(t), 0.0, 0.0, 1.0);
        \\}
    ;

    const metadata = analyzeShader(src);
    try testing.expectEqual(@as(?f32, null), metadata.cursor_animation_duration);
    try testing.expectEqual(true, metadata.is_continuous);
}

test "analyzeShader cursor without duration" {
    const testing = std.testing;

    // Shader with cursor uniforms and iTime but no DURATION (continuous)
    const src =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec4 cursor = iCurrentCursor;
        \\    float t = iTime;
        \\    fragColor = vec4(1.0);
        \\}
    ;

    const metadata = analyzeShader(src);
    try testing.expectEqual(@as(?f32, null), metadata.cursor_animation_duration);
    try testing.expectEqual(true, metadata.is_continuous);
}

test "analyzeShader no animation" {
    const testing = std.testing;

    // Simple shader with no time or cursor uniforms
    const src =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    fragColor = vec4(1.0, 0.0, 0.0, 1.0);
        \\}
    ;

    const metadata = analyzeShader(src);
    try testing.expectEqual(@as(?f32, null), metadata.cursor_animation_duration);
    try testing.expectEqual(false, metadata.is_continuous);
}

test "findDurationConstant variations" {
    const testing = std.testing;

    // Standard format
    try testing.expectEqual(@as(?f32, 0.5), findDurationConstant("const float DURATION = 0.5;"));

    // No spaces around equals
    try testing.expectEqual(@as(?f32, 1.0), findDurationConstant("const float DURATION=1.0;"));

    // Integer value
    try testing.expectEqual(@as(?f32, 2.0), findDurationConstant("DURATION = 2;"));

    // Leading dot
    try testing.expectEqual(@as(?f32, 0.3), findDurationConstant("DURATION = .3;"));

    // Not found
    try testing.expectEqual(@as(?f32, null), findDurationConstant("const float TIME = 1.0;"));

    // Too large (>= 60s)
    try testing.expectEqual(@as(?f32, null), findDurationConstant("DURATION = 100.0;"));
}
