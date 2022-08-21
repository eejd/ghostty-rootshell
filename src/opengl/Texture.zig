const Texture = @This();

const std = @import("std");
const c = @import("c.zig");
const errors = @import("errors.zig");

id: c.GLuint,

pub inline fn active(target: c.GLenum) !void {
    c.glActiveTexture(target);
}

/// Enun for possible texture binding targets.
pub const Target = enum(c_uint) {
    @"1D" = c.GL_TEXTURE_1D,
    @"2D" = c.GL_TEXTURE_2D,
    @"3D" = c.GL_TEXTURE_3D,
    @"1DArray" = c.GL_TEXTURE_1D_ARRAY,
    @"2DArray" = c.GL_TEXTURE_2D_ARRAY,
    Rectangle = c.GL_TEXTURE_RECTANGLE,
    CubeMap = c.GL_TEXTURE_CUBE_MAP,
    Buffer = c.GL_TEXTURE_BUFFER,
    @"2DMultisample" = c.GL_TEXTURE_2D_MULTISAMPLE,
    @"2DMultisampleArray" = c.GL_TEXTURE_2D_MULTISAMPLE_ARRAY,
};

/// Enum for possible texture parameters.
pub const Parameter = enum(c_uint) {
    BaseLevel = c.GL_TEXTURE_BASE_LEVEL,
    CompareFunc = c.GL_TEXTURE_COMPARE_FUNC,
    CompareMode = c.GL_TEXTURE_COMPARE_MODE,
    LodBias = c.GL_TEXTURE_LOD_BIAS,
    MinFilter = c.GL_TEXTURE_MIN_FILTER,
    MagFilter = c.GL_TEXTURE_MAG_FILTER,
    MinLod = c.GL_TEXTURE_MIN_LOD,
    MaxLod = c.GL_TEXTURE_MAX_LOD,
    MaxLevel = c.GL_TEXTURE_MAX_LEVEL,
    SwizzleR = c.GL_TEXTURE_SWIZZLE_R,
    SwizzleG = c.GL_TEXTURE_SWIZZLE_G,
    SwizzleB = c.GL_TEXTURE_SWIZZLE_B,
    SwizzleA = c.GL_TEXTURE_SWIZZLE_A,
    WrapS = c.GL_TEXTURE_WRAP_S,
    WrapT = c.GL_TEXTURE_WRAP_T,
    WrapR = c.GL_TEXTURE_WRAP_R,
};

/// Internal format enum for texture images.
pub const InternalFormat = enum(c_int) {
    Red = c.GL_RED,
    RGBA = c.GL_RGBA,

    // There are so many more that I haven't filled in.
    _,
};

/// Format for texture images
pub const Format = enum(c_uint) {
    Red = c.GL_RED,
    BGRA = c.GL_BGRA,

    // There are so many more that I haven't filled in.
    _,
};

/// Data type for texture images.
pub const DataType = enum(c_uint) {
    UnsignedByte = c.GL_UNSIGNED_BYTE,

    // There are so many more that I haven't filled in.
    _,
};

pub const Binding = struct {
    target: Target,

    pub inline fn unbind(b: *Binding) void {
        c.glBindTexture(@enumToInt(b.target), 0);
        b.* = undefined;
    }

    pub fn generateMipmap(b: Binding) void {
        c.glGenerateMipmap(@enumToInt(b.target));
    }

    pub fn parameter(b: Binding, name: Parameter, value: anytype) !void {
        switch (@TypeOf(value)) {
            c.GLint => c.glTexParameteri(
                @enumToInt(b.target),
                @enumToInt(name),
                value,
            ),
            else => unreachable,
        }
    }

    pub fn image2D(
        b: Binding,
        level: c.GLint,
        internal_format: InternalFormat,
        width: c.GLsizei,
        height: c.GLsizei,
        border: c.GLint,
        format: Format,
        typ: DataType,
        data: ?*const anyopaque,
    ) !void {
        c.glTexImage2D(
            @enumToInt(b.target),
            level,
            @enumToInt(internal_format),
            width,
            height,
            border,
            @enumToInt(format),
            @enumToInt(typ),
            data,
        );
    }

    pub fn subImage2D(
        b: Binding,
        level: c.GLint,
        xoffset: c.GLint,
        yoffset: c.GLint,
        width: c.GLsizei,
        height: c.GLsizei,
        format: Format,
        typ: DataType,
        data: ?*const anyopaque,
    ) !void {
        c.glTexSubImage2D(
            @enumToInt(b.target),
            level,
            xoffset,
            yoffset,
            width,
            height,
            @enumToInt(format),
            @enumToInt(typ),
            data,
        );
    }
};

/// Create a single texture.
pub inline fn create() !Texture {
    var id: c.GLuint = undefined;
    c.glGenTextures(1, &id);
    return Texture{ .id = id };
}

/// glBindTexture
pub inline fn bind(v: Texture, target: Target) !Binding {
    c.glBindTexture(@enumToInt(target), v.id);
    return Binding{ .target = target };
}

pub inline fn destroy(v: Texture) void {
    c.glDeleteTextures(1, &v.id);
}
