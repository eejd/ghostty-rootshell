const std = @import("std");
const fs = std.fs;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const glfw = @import("vendor/mach/glfw/build.zig");
const freetype = @import("pkg/freetype/build.zig");
const libuv = @import("pkg/libuv/build.zig");
const tracylib = @import("src/tracy/build.zig");
const system_sdk = @import("vendor/mach/glfw/system_sdk.zig");

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = target: {
        var result = b.standardTargetOptions(.{});

        if (result.isLinux() and result.isGnuLibC()) {
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

    const exe = b.addExecutable("ghostty", "src/main.zig");

    // Exe
    {
        const exe_options = b.addOptions();
        exe_options.addOption(bool, "tracy_enabled", tracy);

        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addOptions("build_options", exe_options);
        exe.install();

        // Add the shared dependencies
        try addDeps(b, exe);
    }

    // term.wasm
    {
        const wasm = b.addSharedLibrary(
            "ghostty-term",
            "src/terminal/main_wasm.zig",
            .{ .unversioned = {} },
        );
        wasm.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        wasm.setBuildMode(mode);
        wasm.setOutputDir("zig-out");
        wasm.addPackage(tracylib.pkg);

        const step = b.step("term-wasm", "Build the terminal.wasm library");
        step.dependOn(&wasm.step);
    }

    // Run
    {
        // Build our run step, which runs the main app by default, but will
        // run a conformance app if `-Dconformance` is set.
        const run_exe = if (conformance) |name| blk: {
            var conformance_exes = try conformanceSteps(b, target, mode);
            defer conformance_exes.deinit();
            break :blk conformance_exes.get(name) orelse return error.InvalidConformance;
        } else exe;
        const run_cmd = run_exe.run();
        run_cmd.step.dependOn(&run_exe.step);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    {
        const test_step = b.step("test", "Run all tests");
        var test_bin_ = b.option([]const u8, "test-bin", "Emit bin to");
        var test_filter = b.option([]const u8, "test-filter", "Filter for test");

        const main_test = b.addTest("src/main.zig");
        {
            main_test.setFilter(test_filter);
            if (test_bin_) |test_bin| {
                main_test.name = std.fs.path.basename(test_bin);
                if (std.fs.path.dirname(test_bin)) |dir| main_test.setOutputDir(dir);
            }

            main_test.setTarget(target);
            try addDeps(b, main_test);

            var before = b.addLog("\x1b[" ++ color_map.get("cyan").? ++ "\x1b[" ++ color_map.get("b").? ++ "[{s} tests]" ++ "\x1b[" ++ color_map.get("d").? ++ " ----" ++ "\x1b[0m", .{"ghostty"});
            var after = b.addLog("\x1b[" ++ color_map.get("d").? ++ "–––---\n\n" ++ "\x1b[0m", .{});
            test_step.dependOn(&before.step);
            test_step.dependOn(&main_test.step);
            test_step.dependOn(&after.step);
        }

        // Named package dependencies don't have their tests run by reference,
        // so we iterate through them here. We're only interested in dependencies
        // we wrote (are in the "pkg/" directory).
        for (main_test.packages.items) |pkg_| {
            const pkg: std.build.Pkg = pkg_;
            if (std.mem.eql(u8, pkg.name, "glfw")) continue;
            var test_ = b.addTestSource(pkg.source);

            test_.setTarget(target);
            try addDeps(b, test_);
            if (pkg.dependencies) |children| {
                test_.packages = std.ArrayList(std.build.Pkg).init(b.allocator);
                try test_.packages.appendSlice(children);
            }

            var before = b.addLog("\x1b[" ++ color_map.get("cyan").? ++ "\x1b[" ++ color_map.get("b").? ++ "[{s} tests]" ++ "\x1b[" ++ color_map.get("d").? ++ " ----" ++ "\x1b[0m", .{pkg.name});
            var after = b.addLog("\x1b[" ++ color_map.get("d").? ++ "–––---\n\n" ++ "\x1b[0m", .{});
            test_step.dependOn(&before.step);
            test_step.dependOn(&test_.step);
            test_step.dependOn(&after.step);
        }
    }
}

/// Adds and links all of the primary dependencies for the exe.
fn addDeps(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
) !void {
    step.addIncludeDir("src/");
    step.addCSourceFile("src/gb_math.c", &.{});
    step.addIncludeDir("vendor/glad/include/");
    step.addCSourceFile("vendor/glad/src/gl.c", &.{});

    // Freetype
    step.addPackage(freetype.pkg);
    try freetype.link(b, step);

    // Glfw
    step.addPackage(glfw.pkg);
    glfw.link(b, step, .{
        .metal = false,
        .opengl = false, // Found at runtime
    });

    // Libuv
    step.addPackage(libuv.pkg);
    try libuv.link(b, step);

    // Tracy
    step.addPackage(tracylib.pkg);
    try tracylib.link(b, step);
}

fn conformanceSteps(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
) !std.StringHashMap(*LibExeObjStep) {
    var map = std.StringHashMap(*LibExeObjStep).init(b.allocator);

    // Open the directory ./conformance
    const c_dir_path = root() ++ "/conformance";
    var c_dir = try fs.openIterableDirAbsolute(c_dir_path, .{});
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

        // Executable builder.
        const c_exe = b.addExecutable(name, path);
        c_exe.setTarget(target);
        c_exe.setBuildMode(mode);

        // Store the mapping
        try map.put(name, c_exe);
    }

    return map;
}

/// Path to the directory with the build.zig.
fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}

/// ANSI escape codes for colored log output
const color_map = std.ComptimeStringMap([]const u8, .{
    &.{ "black", "30m" },
    &.{ "blue", "34m" },
    &.{ "b", "1m" },
    &.{ "d", "2m" },
    &.{ "cyan", "36m" },
    &.{ "green", "32m" },
    &.{ "magenta", "35m" },
    &.{ "red", "31m" },
    &.{ "white", "37m" },
    &.{ "yellow", "33m" },
});
