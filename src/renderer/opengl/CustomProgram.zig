/// The OpenGL program for custom shaders.
const CustomProgram = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

program: gl.Program,

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

    return .{
        .program = program,
    };
}

pub fn deinit(self: CustomProgram) void {
    self.program.destroy();
}
