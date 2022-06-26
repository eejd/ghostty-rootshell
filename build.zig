const std = @import("std");
const fs = std.fs;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const glfw = @import("vendor/mach/glfw/build.zig");
const ft = @import("src/freetype/build.zig");
const uv = @import("src/libuv/build.zig");
const tracylib = @import("src/tracy/build.zig");
const system_sdk = @import("vendor/mach/glfw/system_sdk.zig");

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = target: {
        var result = b.standardTargetOptions(.{});

        if (result.isLinux()) {
            // https://github.com/ziglang/zig/issues/9485
            result.glibc_version = .{ .major = 2, .minor = 28 };
        }

        break :target result;
    };

    const tracy = b.option(
        bool,
        "tracy",
        "Enable Tracy integration (default true in Debug on Linux)",
    ) orelse (mode == .Debug and target.isLinux());

    const conformance = b.option(
        []const u8,
        "conformance",
        "Name of the conformance app to run with 'run' option.",
    );

    const exe_options = b.addOptions();
    exe_options.addOption(bool, "tracy_enabled", tracy);

    const exe = b.addExecutable("ghostty", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addOptions("build_options", exe_options);
    exe.install();
    exe.addIncludeDir("src/");
    exe.addCSourceFile("src/gb_math.c", &.{});
    exe.addPackagePath("glfw", "vendor/mach/glfw/src/main.zig");
    glfw.link(b, exe, .{
        .metal = false,
        .opengl = false, // Found at runtime
    });

    // Tracy
    if (tracy) try tracylib.link(b, exe, target);

    // GLAD
    exe.addIncludeDir("vendor/glad/include/");
    exe.addCSourceFile("vendor/glad/src/gl.c", &.{});

    const ftlib = try ft.create(b, target, mode, .{});
    ftlib.link(exe);

    const libuv = try uv.create(b, target, mode);
    system_sdk.include(b, libuv.step, .{});
    libuv.link(exe);

    // stb if we need it
    // exe.addIncludeDir("vendor/stb");
    // exe.addCSourceFile("src/stb/stb.c", &.{});

    // Conformance apps
    var conformance_exes = try conformanceSteps(b, target, mode);
    defer conformance_exes.deinit();

    // Build our run step, which runs the main app by default, but will
    // run a conformance app if `-Dconformance` is set.
    const run_exe = if (conformance) |name|
        conformance_exes.get(name) orelse return error.InvalidConformance
    else
        exe;
    const run_cmd = run_exe.run();
    run_cmd.step.dependOn(&run_exe.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run all tests");
    const lib_tests = b.addTest("src/main.zig");
    ftlib.link(lib_tests);
    libuv.link(lib_tests);
    lib_tests.setTarget(target);
    lib_tests.addIncludeDir("vendor/glad/include/");
    lib_tests.addCSourceFile("vendor/glad/src/gl.c", &.{});
    test_step.dependOn(&lib_tests.step);
}

fn conformanceSteps(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
) !std.StringHashMap(*LibExeObjStep) {
    var map = std.StringHashMap(*LibExeObjStep).init(b.allocator);

    // Open the directory ./conformance
    const c_dir_path = root() ++ "/conformance";
    var c_dir = try fs.openDirAbsolute(c_dir_path, .{ .iterate = true });
    defer c_dir.close();

    // Go through and add each as a step
    var c_dir_it = c_dir.iterate();
    while (try c_dir_it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (index == 0) continue;

        // Name of the conformance app and full path to the entrypoint.
        const name = entry.name[0..index];
        const path = try fs.path.join(b.allocator, &[_][]const u8{
            c_dir_path,
            entry.name,
        });

        // Executable builder. We install all conformance tests so that
        // `zig build` verifies they work.
        const c_exe = b.addExecutable(name, path);
        c_exe.setTarget(target);
        c_exe.setBuildMode(mode);
        c_exe.install();

        // Store the mapping
        try map.put(name, c_exe);
    }

    return map;
}

/// Path to the directory with the build.zig.
fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}
