const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = target;
    _ = optimize;
}

pub fn addPaths(b: *std.Build, step: *std.Build.Step.Compile) !void {
    _ = b;
    @import("macos_sdk").addPaths(step);
}

pub fn addPathsModule(b: *std.Build, m: *std.Build.Module) !void {
    _ = b;
    @import("macos_sdk").addPathsModule(m);
}
