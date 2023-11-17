const Framebuffer = @This();

const std = @import("std");
const c = @import("c.zig");
const errors = @import("errors.zig");
const glad = @import("glad.zig");
const Texture = @import("Texture.zig");

id: c.GLuint,

/// Create a single buffer.
pub fn create() !Framebuffer {
    var fbo: c.GLuint = undefined;
    glad.context.GenFramebuffers.?(1, &fbo);
    return .{ .id = fbo };
}

pub fn destroy(v: Framebuffer) void {
    glad.context.DeleteFramebuffers.?(1, &v.id);
}

pub fn bind(v: Framebuffer, target: Target) !Binding {
    glad.context.BindFramebuffer.?(@intFromEnum(target), v.id);
    return .{ .target = target };
}

/// Enum for possible binding targets.
pub const Target = enum(c_uint) {
    framebuffer = c.GL_FRAMEBUFFER,
    draw = c.GL_DRAW_FRAMEBUFFER,
    read = c.GL_READ_FRAMEBUFFER,
    _,
};

pub const Attachment = enum(c_uint) {
    color0 = c.GL_COLOR_ATTACHMENT0,
    depth = c.GL_DEPTH_ATTACHMENT,
    stencil = c.GL_STENCIL_ATTACHMENT,
    depth_stencil = c.GL_DEPTH_STENCIL_ATTACHMENT,
    _,
};

pub const Status = enum(c_uint) {
    complete = c.GL_FRAMEBUFFER_COMPLETE,
    undefined = c.GL_FRAMEBUFFER_UNDEFINED,
    incomplete_attachment = c.GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT,
    incomplete_missing_attachment = c.GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT,
    incomplete_draw_buffer = c.GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER,
    incomplete_read_buffer = c.GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER,
    unsupported = c.GL_FRAMEBUFFER_UNSUPPORTED,
    incomplete_multisample = c.GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE,
    incomplete_layer_targets = c.GL_FRAMEBUFFER_INCOMPLETE_LAYER_TARGETS,
    _,
};

pub const Binding = struct {
    target: Target,

    pub fn unbind(self: Binding) void {
        glad.context.BindFramebuffer.?(@intFromEnum(self.target), 0);
    }

    pub fn texture2D(
        self: Binding,
        attachment: Attachment,
        textarget: Texture.Target,
        texture: Texture,
        level: c.GLint,
    ) !void {
        glad.context.FramebufferTexture2D.?(
            @intFromEnum(self.target),
            @intFromEnum(attachment),
            @intFromEnum(textarget),
            texture.id,
            level,
        );
        try errors.getError();
    }

    pub fn checkStatus(self: Binding) Status {
        return @enumFromInt(glad.context.CheckFramebufferStatus.?(self.target));
    }
};
