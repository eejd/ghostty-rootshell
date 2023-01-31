const std = @import("std");
const fs = std.fs;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const glfw = @import("vendor/mach/libs/glfw/build.zig");
const fontconfig = @import("pkg/fontconfig/build.zig");
const freetype = @import("pkg/freetype/build.zig");
const harfbuzz = @import("pkg/harfbuzz/build.zig");
const imgui = @import("pkg/imgui/build.zig");
const js = @import("vendor/zig-js/build.zig");
const libxev = @import("vendor/libxev/build.zig");
const libxml2 = @import("vendor/zig-libxml2/libxml2.zig");
const libuv = @import("pkg/libuv/build.zig");
const libpng = @import("pkg/libpng/build.zig");
const macos = @import("pkg/macos/build.zig");
const objc = @import("vendor/zig-objc/build.zig");
const pixman = @import("pkg/pixman/build.zig");
const stb_image_resize = @import("pkg/stb_image_resize/build.zig");
const utf8proc = @import("pkg/utf8proc/build.zig");
const zlib = @import("pkg/zlib/build.zig");
const tracylib = @import("pkg/tracy/build.zig");
const system_sdk = @import("vendor/mach/libs/glfw/system_sdk.zig");
const WasmTarget = @import("src/os/wasm/target.zig").Target;

// Build options, see the build options help for more info.
var tracy: bool = false;
var enable_coretext: bool = false;
var enable_fontconfig: bool = false;

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

    tracy = b.option(
        bool,
        "tracy",
        "Enable Tracy integration (default true in Debug on Linux)",
    ) orelse (mode == .Debug and target.isLinux());

    enable_coretext = b.option(
        bool,
        "coretext",
        "Enable coretext for font discovery (default true on macOS)",
    ) orelse target.isDarwin();

    enable_fontconfig = b.option(
        bool,
        "fontconfig",
        "Enable fontconfig for font discovery (default true on Linux)",
    ) orelse target.isLinux();

    const static = b.option(
        bool,
        "static",
        "Statically build as much as possible for the exe",
    ) orelse true;

    const conformance = b.option(
        []const u8,
        "conformance",
        "Name of the conformance app to run with 'run' option.",
    );

    const emit_test_exe = b.option(
        bool,
        "test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    // We can use wasmtime to test wasm
    b.enable_wasmtime = true;

    // Add our benchmarks
    try benchSteps(b, target, mode);

    const exe = b.addExecutable("ghostty", "src/main.zig");
    const exe_options = b.addOptions();
    exe_options.addOption(bool, "tracy_enabled", tracy);
    exe_options.addOption(bool, "coretext", enable_coretext);
    exe_options.addOption(bool, "fontconfig", enable_fontconfig);

    // Exe
    {
        if (target.isDarwin()) {
            // See the comment in this file
            exe.addCSourceFile("src/renderer/metal_workaround.c", &.{});
        }

        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addOptions("build_options", exe_options);
        exe.install();

        // Add the shared dependencies
        try addDeps(b, exe, static);
    }

    // App (Mac)
    if (target.isDarwin()) {
        const bin_path = try std.fmt.allocPrint(b.allocator, "{s}/bin/ghostty", .{b.install_path});
        b.installFile(bin_path, "Ghostty.app/Contents/MacOS/ghostty");
        b.installFile("dist/macos/Info.plist", "Ghostty.app/Contents/Info.plist");
        b.installFile("dist/macos/Ghostty.icns", "Ghostty.app/Contents/Resources/Ghostty.icns");
    }

    // wasm
    {
        // Build our Wasm target.
        const wasm_target: std.zig.CrossTarget = .{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
            .cpu_features_add = std.Target.wasm.featureSet(&.{
                // We use this to explicitly request shared memory.
                .atomics,

                // Not explicitly used but compiler could use them if they want.
                .bulk_memory,
                .reference_types,
                .sign_ext,
            }),
        };

        // Whether we're using wasm shared memory. Some behaviors change.
        // For now we require this but I wanted to make the code handle both
        // up front.
        const wasm_shared: bool = true;
        exe_options.addOption(bool, "wasm_shared", wasm_shared);

        // We want to support alternate wasm targets in the future (i.e.
        // server side) so we have this now although its hardcoded.
        const wasm_specific_target: WasmTarget = .browser;
        exe_options.addOption(WasmTarget, "wasm_target", wasm_specific_target);

        const wasm = b.addSharedLibrary(
            "ghostty-wasm",
            "src/main_wasm.zig",
            .{ .unversioned = {} },
        );
        wasm.setTarget(wasm_target);
        wasm.setBuildMode(mode);
        wasm.setOutputDir("zig-out");
        wasm.addOptions("build_options", exe_options);

        // So that we can use web workers with our wasm binary
        wasm.import_memory = true;
        wasm.initial_memory = 65536 * 25;
        wasm.max_memory = 65536 * 65536; // Maximum number of pages in wasm32
        wasm.shared_memory = wasm_shared;

        // Stack protector adds extern requirements that we don't satisfy.
        wasm.stack_protector = false;

        // Wasm-specific deps
        try addDeps(b, wasm, true);

        const step = b.step("wasm", "Build the wasm library");
        step.dependOn(&wasm.step);

        // We support tests via wasmtime. wasmtime uses WASI so this
        // isn't an exact match to our freestanding target above but
        // it lets us test some basic functionality.
        const test_step = b.step("test-wasm", "Run all tests for wasm");
        const main_test = b.addTest("src/main_wasm.zig");
        main_test.setTarget(wasm_target);
        main_test.addOptions("build_options", exe_options);
        try addDeps(b, main_test, true);
        test_step.dependOn(&main_test.step);
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
        var test_filter = b.option([]const u8, "test-filter", "Filter for test");

        const main_test = b.addTestExe("ghostty-test", "src/main.zig");
        {
            if (emit_test_exe) main_test.install();
            const main_test_run = main_test.run();
            main_test.setFilter(test_filter);
            main_test.setTarget(target);
            try addDeps(b, main_test, true);
            main_test.addOptions("build_options", exe_options);

            var before = b.addLog("\x1b[" ++ color_map.get("cyan").? ++ "\x1b[" ++ color_map.get("b").? ++ "[{s} tests]" ++ "\x1b[" ++ color_map.get("d").? ++ " ----" ++ "\x1b[0m", .{"ghostty"});
            var after = b.addLog("\x1b[" ++ color_map.get("d").? ++ "–––---\n\n" ++ "\x1b[0m", .{});
            test_step.dependOn(&before.step);
            test_step.dependOn(&main_test_run.step);
            test_step.dependOn(&after.step);
        }

        // Named package dependencies don't have their tests run by reference,
        // so we iterate through them here. We're only interested in dependencies
        // we wrote (are in the "pkg/" directory).
        for (main_test.packages.items) |pkg_| {
            const pkg: std.build.Pkg = pkg_;
            if (std.mem.eql(u8, pkg.name, "build_options")) continue;
            if (std.mem.eql(u8, pkg.name, "glfw")) continue;

            var buf: [256]u8 = undefined;
            var test_ = b.addTestExeSource(
                try std.fmt.bufPrint(&buf, "{s}-test", .{pkg.name}),
                pkg.source,
            );
            const test_run = test_.run();

            test_.setTarget(target);
            try addDeps(b, test_, true);
            if (pkg.dependencies) |children| {
                test_.packages = std.ArrayList(std.build.Pkg).init(b.allocator);
                try test_.packages.appendSlice(children);
            }

            var before = b.addLog("\x1b[" ++ color_map.get("cyan").? ++ "\x1b[" ++ color_map.get("b").? ++ "[{s} tests]" ++ "\x1b[" ++ color_map.get("d").? ++ " ----" ++ "\x1b[0m", .{pkg.name});
            var after = b.addLog("\x1b[" ++ color_map.get("d").? ++ "–––---\n\n" ++ "\x1b[0m", .{});
            test_step.dependOn(&before.step);
            test_step.dependOn(&test_run.step);
            test_step.dependOn(&after.step);

            if (emit_test_exe) test_.install();
        }
    }
}

/// Adds and links all of the primary dependencies for the exe.
fn addDeps(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    static: bool,
) !void {
    // Wasm we do manually since it is such a different build.
    if (step.target.getCpuArch() == .wasm32) {
        // We link this package but its a no-op since Tracy
        // never actualy WORKS with wasm.
        step.addPackage(tracylib.pkg);
        step.addPackage(utf8proc.pkg);
        step.addPackage(js.pkg);

        // utf8proc
        _ = try utf8proc.link(b, step);

        return;
    }

    // We always need the Zig packages
    if (enable_fontconfig) step.addPackage(fontconfig.pkg);
    step.addPackage(freetype.pkg);
    step.addPackage(harfbuzz.pkg);
    step.addPackage(imgui.pkg);
    step.addPackage(glfw.pkg);
    step.addPackage(libxev.pkg);
    step.addPackage(libuv.pkg);
    step.addPackage(pixman.pkg);
    step.addPackage(stb_image_resize.pkg);
    step.addPackage(utf8proc.pkg);

    // Mac Stuff
    if (step.target.isDarwin()) {
        step.addPackage(objc.pkg);
        step.addPackage(macos.pkg);
        _ = try macos.link(b, step, .{});
    }

    // We always statically compile glad
    step.addIncludePath("vendor/glad/include/");
    step.addCSourceFile("vendor/glad/src/gl.c", &.{});

    // Tracy
    step.addPackage(tracylib.pkg);
    if (tracy) {
        var tracy_step = try tracylib.link(b, step);
        system_sdk.include(b, tracy_step, .{});
    }

    // stb_image_resize
    _ = try stb_image_resize.link(b, step, .{});

    // utf8proc
    _ = try utf8proc.link(b, step);

    // Glfw
    const glfw_opts: glfw.Options = .{
        .metal = step.target.isDarwin(),
        .opengl = false,
    };
    try glfw.link(b, step, glfw_opts);

    // Imgui, we have to do this later since we need some information
    const imgui_backends = if (step.target.isDarwin())
        &[_][]const u8{ "glfw", "opengl3", "metal" }
    else
        &[_][]const u8{ "glfw", "opengl3" };
    var imgui_opts: imgui.Options = .{
        .backends = imgui_backends,
        .freetype = .{ .enabled = true },
    };

    // Dynamic link
    if (!static) {
        step.addIncludePath(freetype.include_path_self);
        step.linkSystemLibrary("bzip2");
        step.linkSystemLibrary("freetype2");
        step.linkSystemLibrary("harfbuzz");
        step.linkSystemLibrary("libpng");
        step.linkSystemLibrary("libuv");
        step.linkSystemLibrary("pixman-1");
        step.linkSystemLibrary("zlib");

        if (enable_fontconfig) step.linkSystemLibrary("fontconfig");
    }

    // Other dependencies, we may dynamically link
    if (static) {
        const zlib_step = try zlib.link(b, step);
        const libpng_step = try libpng.link(b, step, .{
            .zlib = .{
                .step = zlib_step,
                .include = &zlib.include_paths,
            },
        });

        // Freetype
        const freetype_step = try freetype.link(b, step, .{
            .libpng = freetype.Options.Libpng{
                .enabled = true,
                .step = libpng_step,
                .include = &libpng.include_paths,
            },

            .zlib = .{
                .enabled = true,
                .step = zlib_step,
                .include = &zlib.include_paths,
            },
        });

        // Harfbuzz
        const harfbuzz_step = try harfbuzz.link(b, step, .{
            .freetype = .{
                .enabled = true,
                .step = freetype_step,
                .include = &freetype.include_paths,
            },

            .coretext = .{
                .enabled = enable_coretext,
            },
        });
        system_sdk.include(b, harfbuzz_step, .{});

        // Pixman
        const pixman_step = try pixman.link(b, step, .{});
        _ = pixman_step;

        // Libuv
        const libuv_step = try libuv.link(b, step);
        system_sdk.include(b, libuv_step, .{});

        // Only Linux gets fontconfig
        if (enable_fontconfig) {
            // Libxml2
            const libxml2_lib = try libxml2.create(
                b,
                step.target,
                step.build_mode,
                .{ .lzma = false, .zlib = false },
            );
            libxml2_lib.link(step);

            // Fontconfig
            const fontconfig_step = try fontconfig.link(b, step, .{
                .freetype = .{
                    .enabled = true,
                    .step = freetype_step,
                    .include = &freetype.include_paths,
                },

                .libxml2 = true,
            });
            libxml2_lib.link(fontconfig_step);
        }

        // Imgui
        imgui_opts.freetype.step = freetype_step;
        imgui_opts.freetype.include = &freetype.include_paths;
    }

    // Imgui
    const imgui_step = try imgui.link(b, step, imgui_opts);
    try glfw.link(b, imgui_step, glfw_opts);
}

fn benchSteps(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
) !void {
    // Open the directory ./src/bench
    const c_dir_path = (comptime root()) ++ "/src/bench";
    var c_dir = try fs.openIterableDirAbsolute(c_dir_path, .{});
    defer c_dir.close();

    // Go through and add each as a step
    var c_dir_it = c_dir.iterate();
    while (try c_dir_it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (index == 0) continue;

        // If it doesn't end in 'zig' then ignore
        if (!std.mem.eql(u8, entry.name[index + 1 ..], "zig")) continue;

        // Name of the conformance app and full path to the entrypoint.
        const name = entry.name[0..index];
        const path = try fs.path.join(b.allocator, &[_][]const u8{
            c_dir_path,
            entry.name,
        });

        // Executable builder.
        const bin_name = try std.fmt.allocPrint(b.allocator, "bench-{s}", .{name});
        const c_exe = b.addExecutable(bin_name, path);
        c_exe.setTarget(target);
        c_exe.setBuildMode(mode);
        c_exe.setMainPkgPath("./src");
        c_exe.install();
        try addDeps(b, c_exe, true);
    }
}

fn conformanceSteps(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
) !std.StringHashMap(*LibExeObjStep) {
    var map = std.StringHashMap(*LibExeObjStep).init(b.allocator);

    // Open the directory ./conformance
    const c_dir_path = (comptime root()) ++ "/conformance";
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
