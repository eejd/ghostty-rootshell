const std = @import("std");

pub fn build(b: *std.Build) !void {
    const module = b.addModule("opengl", .{ .root_source_file = .{ .path = "main.zig" } });
    module.addIncludePath(.{ .path = "../../vendor/glad/include" });
}
