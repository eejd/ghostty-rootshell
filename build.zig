const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const RunStep = std.build.RunStep;
const apprt = @import("src/apprt.zig");
const glfw = @import("vendor/mach/libs/glfw/build.zig");
const fontconfig = @import("pkg/fontconfig/build.zig");
const freetype = @import("pkg/freetype/build.zig");
const harfbuzz = @import("pkg/harfbuzz/build.zig");
const imgui = @import("pkg/imgui/build.zig");
const js = @import("vendor/zig-js/build.zig");
const libxev = @import("vendor/libxev/build.zig");
const libxml2 = @import("vendor/zig-libxml2/libxml2.zig");
const libpng = @import("pkg/libpng/build.zig");
const macos = @import("pkg/macos/build.zig");
const objc = @import("vendor/zig-objc/build.zig");
const pixman = @import("pkg/pixman/build.zig");
const stb_image_resize = @import("pkg/stb_image_resize/build.zig");
const utf8proc = @import("pkg/utf8proc/build.zig");
const zlib = @import("pkg/zlib/build.zig");
const tracylib = @import("pkg/tracy/build.zig");
const system_sdk = @import("vendor/mach/libs/glfw/system_sdk.zig");
const font = @import("src/font/main.zig");
const WasmTarget = @import("src/os/wasm/target.zig").Target;
const LibtoolStep = @import("src/build/LibtoolStep.zig");
const LipoStep = @import("src/build/LipoStep.zig");
const XCFrameworkStep = @import("src/build/XCFrameworkStep.zig");
const Version = @import("src/build/Version.zig");

// Do a comptime Zig version requirement. The required Zig version is
// somewhat arbitrary: it is meant to be a version that we feel works well,
// but we liberally update it. In the future, we'll be more careful about
// using released versions so that package managers can integrate better.
comptime {
    const required_zig = "0.11.0-dev.1635+d09e39aef";
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the minimum build requirement of v{}",
            .{ current_zig, min_zig },
        ));
    }
}

/// The version of the next release.
const app_version = std.builtin.Version{ .major = 0, .minor = 1, .patch = 0 };

/// Build options, see the build options help for more info.
var tracy: bool = false;
var flatpak: bool = false;
var app_runtime: apprt.Runtime = .none;
var font_backend: font.Backend = .freetype;

pub fn build(b: *std.build.Builder) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = target: {
        var result = b.standardTargetOptions(.{});

        if (result.isLinux() and result.isGnuLibC()) {
            // https://github.com/ziglang/zig/issues/9485
            result.glibc_version = .{ .major = 2, .minor = 28 };
        }

        break :target result;
    };

    const wasm_target: WasmTarget = .browser;

    // We use env vars throughout the build so we grab them immediately here.
    var env = try std.process.getEnvMap(b.allocator);
    defer env.deinit();

    tracy = b.option(
        bool,
        "tracy",
        "Enable Tracy integration (default true in Debug on Linux)",
    ) orelse (optimize == .Debug and target.isLinux());

    flatpak = b.option(
        bool,
        "flatpak",
        "Build for Flatpak (integrates with Flatpak APIs). Only has an effect targeting Linux.",
    ) orelse false;

    font_backend = b.option(
        font.Backend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse font.Backend.default(target, wasm_target);

    app_runtime = b.option(
        apprt.Runtime,
        "app-runtime",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse apprt.Runtime.default(target);

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
        "emit-test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    const emit_bench = b.option(
        bool,
        "emit-bench",
        "Build and install the benchmark executables.",
    ) orelse false;

    // On NixOS, the built binary from `zig build` needs to patch the rpath
    // into the built binary for it to be portable across the NixOS system
    // it was built for. We default this to true if we can detect we're in
    // a Nix shell and have LD_LIBRARY_PATH set.
    const patch_rpath: ?[]const u8 = b.option(
        []const u8,
        "patch-rpath",
        "Inject the LD_LIBRARY_PATH as the rpath in the built binary. " ++
            "This defaults to LD_LIBRARY_PATH if we're in a Nix shell environment on NixOS.",
    ) orelse patch_rpath: {
        // We only do the patching if we're targeting our own CPU and its Linux.
        if (!target.isLinux() or !target.isNativeCpu()) break :patch_rpath null;

        // If we're in a nix shell we default to doing this.
        // Note: we purposely never deinit envmap because we leak the strings
        if (env.get("IN_NIX_SHELL") == null) break :patch_rpath null;
        break :patch_rpath env.get("LD_LIBRARY_PATH");
    };

    var version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );

    var version: std.SemanticVersion = if (version_string) |v|
        try std.SemanticVersion.parse(v)
    else version: {
        const vsn = try Version.detect(b);
        if (vsn.tag) |tag| {
            // Tip releases behave just like any other pre-release so we skip.
            if (!std.mem.eql(u8, tag, "tip")) {
                const expected = b.fmt("v{d}.{d}.{d}", .{
                    app_version.major,
                    app_version.minor,
                    app_version.patch,
                });

                if (!std.mem.eql(u8, tag, expected)) {
                    @panic("tagged releases must be in vX.Y.Z format matching build.zig");
                }

                break :version .{
                    .major = app_version.major,
                    .minor = app_version.minor,
                    .patch = app_version.patch,
                };
            }
        }

        break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
            .pre = vsn.branch,
            .build = vsn.short_hash,
        };
    };

    // We can use wasmtime to test wasm
    b.enable_wasmtime = true;

    // Add our benchmarks
    try benchSteps(b, target, optimize, emit_bench);

    const exe = b.addExecutable(.{
        .name = "ghostty",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const exe_options = b.addOptions();
    exe_options.addOption(std.SemanticVersion, "app_version", version);
    exe_options.addOption([]const u8, "app_version_string", b.fmt("{}", .{version}));
    exe_options.addOption(bool, "tracy_enabled", tracy);
    exe_options.addOption(bool, "flatpak", flatpak);
    exe_options.addOption(apprt.Runtime, "app_runtime", app_runtime);
    exe_options.addOption(font.Backend, "font_backend", font_backend);

    // Exe
    {
        exe.addOptions("build_options", exe_options);

        if (target.isDarwin()) {
            // See the comment in this file
            exe.addCSourceFile("src/renderer/metal_workaround.c", &.{});
        }

        // Add the shared dependencies
        _ = try addDeps(b, exe, static);

        // If we're in NixOS but not in the shell environment then we issue
        // a warning because the rpath may not be setup properly.
        const is_nixos = is_nixos: {
            if (!target.isLinux()) break :is_nixos false;
            if (!target.isNativeCpu()) break :is_nixos false;
            if (target.getOsTag() != builtin.os.tag) break :is_nixos false;
            break :is_nixos if (std.fs.accessAbsolute("/etc/NIXOS", .{})) true else |_| false;
        };
        if (is_nixos and env.get("IN_NIX_SHELL") == null) {
            const notice = b.addLog(
                "\x1b[" ++ color_map.get("yellow").? ++
                    "\x1b[" ++ color_map.get("b").? ++
                    "WARNING: " ++
                    "\x1b[" ++ color_map.get("d").? ++
                    \\Detected building on and for NixOS outside of the Nix shell enviornment.
                    \\
                    \\The resulting ghostty binary will likely fail on launch because it is
                    \\unable to dynamically load the windowing libs (X11, Wayland, etc.).
                    \\We highly recommend running only within the Nix build environment
                    \\and the resulting binary will be portable across your system.
                    \\
                    \\To run in the Nix build environment, use the following command.
                    \\Append any additional options like (`-Doptimize` flags). The resulting
                    \\binary will be in zig-out as usual.
                    \\
                    \\  nix develop -c zig build
                    \\
                    ++
                    "\x1b[0m",
                .{},
            );

            exe.step.dependOn(&notice.step);
        }

        // If we're installing, we get the install step so we can add
        // additional dependencies to it.
        const install_step = if (app_runtime != .none) step: {
            const step = b.addInstallArtifact(exe);
            b.getInstallStep().dependOn(&step.step);
            break :step step;
        } else null;

        // Patch our rpath if that option is specified.
        if (patch_rpath) |rpath| {
            if (rpath.len > 0) {
                const run = RunStep.create(b, "patchelf rpath");
                run.addArgs(&.{ "patchelf", "--set-rpath", rpath });
                run.addArtifactArg(exe);

                if (install_step) |step| {
                    step.step.dependOn(&run.step);
                }
            }
        }
    }

    // App (Linux)
    if (target.isLinux()) {
        // https://developer.gnome.org/documentation/guidelines/maintainer/integrating.html

        // Desktop file so that we have an icon and other metadata
        if (flatpak) {
            b.installFile("dist/linux/app-flatpak.desktop", "share/applications/com.mitchellh.ghostty.desktop");
        } else {
            b.installFile("dist/linux/app.desktop", "share/applications/com.mitchellh.ghostty.desktop");
        }

        // Various icons that our application can use, including the icon
        // that will be used for the desktop.
        b.installFile("images/icons/icon_16x16.png", "share/icons/hicolor/16x16/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_32x32.png", "share/icons/hicolor/32x32/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_128x128.png", "share/icons/hicolor/128x128/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_256x256.png", "share/icons/hicolor/256x256/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_512x512.png", "share/icons/hicolor/512x512/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_16x16@2x@2x.png", "share/icons/hicolor/16x16@2/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_32x32@2x@2x.png", "share/icons/hicolor/32x32@2/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_128x128@2x@2x.png", "share/icons/hicolor/128x128@2/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_256x256@2x@2x.png", "share/icons/hicolor/256x256@2/com.mitchellh.ghostty.png");
    }

    // App (Mac)
    if (target.isDarwin()) {
        const bin_path = try std.fmt.allocPrint(b.allocator, "{s}/bin/ghostty", .{b.install_path});
        b.installFile(bin_path, "Ghostty.app/Contents/MacOS/ghostty");
        b.installFile("dist/macos/Info.plist", "Ghostty.app/Contents/Info.plist");
        b.installFile("dist/macos/Ghostty.icns", "Ghostty.app/Contents/Resources/Ghostty.icns");
    }

    // On Mac we can build the embedding library.
    if (builtin.target.isDarwin()) {
        const static_lib_aarch64 = lib: {
            const lib = b.addStaticLibrary(.{
                .name = "ghostty",
                .root_source_file = .{ .path = "src/main_c.zig" },
                .target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = "aarch64-macos" }),
                .optimize = optimize,
            });
            lib.bundle_compiler_rt = true;
            lib.linkLibC();
            lib.addOptions("build_options", exe_options);

            // See the comment in this file
            lib.addCSourceFile("src/renderer/metal_workaround.c", &.{});

            // Create a single static lib with all our dependencies merged
            var lib_list = try addDeps(b, lib, true);
            try lib_list.append(.{ .generated = &lib.output_path_source });
            const libtool = LibtoolStep.create(b, .{
                .name = "ghostty",
                .out_name = "libghostty-aarch64-fat.a",
                .sources = lib_list.items,
            });
            libtool.step.dependOn(&lib.step);
            b.default_step.dependOn(&libtool.step);

            break :lib libtool;
        };

        const static_lib_x86_64 = lib: {
            const lib = b.addStaticLibrary(.{
                .name = "ghostty",
                .root_source_file = .{ .path = "src/main_c.zig" },
                .target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = "x86_64-macos" }),
                .optimize = optimize,
            });
            lib.bundle_compiler_rt = true;
            lib.linkLibC();
            lib.addOptions("build_options", exe_options);

            // See the comment in this file
            lib.addCSourceFile("src/renderer/metal_workaround.c", &.{});

            // Create a single static lib with all our dependencies merged
            var lib_list = try addDeps(b, lib, true);
            try lib_list.append(.{ .generated = &lib.output_path_source });
            const libtool = LibtoolStep.create(b, .{
                .name = "ghostty",
                .out_name = "libghostty-x86_64-fat.a",
                .sources = lib_list.items,
            });
            libtool.step.dependOn(&lib.step);
            b.default_step.dependOn(&libtool.step);

            break :lib libtool;
        };

        const static_lib_universal = LipoStep.create(b, .{
            .name = "ghostty",
            .out_name = "libghostty.a",
            .input_a = .{ .generated = &static_lib_aarch64.out_path },
            .input_b = .{ .generated = &static_lib_x86_64.out_path },
        });
        static_lib_universal.step.dependOn(&static_lib_aarch64.step);
        static_lib_universal.step.dependOn(&static_lib_x86_64.step);

        // The xcframework wraps our ghostty library so that we can link
        // it to the final app built with Swift.
        const xcframework = XCFrameworkStep.create(b, .{
            .name = "GhosttyKit",
            .out_path = "macos/GhosttyKit.xcframework",
            .library = .{ .generated = &static_lib_universal.out_path },
            .headers = .{ .path = "include" },
        });
        xcframework.step.dependOn(&static_lib_universal.step);
        b.default_step.dependOn(&xcframework.step);
    }

    // wasm
    {
        // Build our Wasm target.
        const wasm_crosstarget: std.zig.CrossTarget = .{
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
        exe_options.addOption(WasmTarget, "wasm_target", wasm_target);

        const wasm = b.addSharedLibrary(.{
            .name = "ghostty-wasm",
            .root_source_file = .{ .path = "src/main_wasm.zig" },
            .target = wasm_crosstarget,
            .optimize = optimize,
        });
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
        _ = try addDeps(b, wasm, true);

        const step = b.step("wasm", "Build the wasm library");
        step.dependOn(&wasm.step);

        // We support tests via wasmtime. wasmtime uses WASI so this
        // isn't an exact match to our freestanding target above but
        // it lets us test some basic functionality.
        const test_step = b.step("test-wasm", "Run all tests for wasm");
        const main_test = b.addTest(.{
            .name = "wasm-test",
            .root_source_file = .{ .path = "src/main_wasm.zig" },
            .target = wasm_crosstarget,
        });
        main_test.addOptions("build_options", exe_options);
        _ = try addDeps(b, main_test, true);
        test_step.dependOn(&main_test.step);
    }

    // Run
    {
        // Build our run step, which runs the main app by default, but will
        // run a conformance app if `-Dconformance` is set.
        const run_exe = if (conformance) |name| blk: {
            var conformance_exes = try conformanceSteps(b, target, optimize);
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

        const main_test = b.addTest(.{
            .name = "ghostty-test",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
        });
        {
            if (emit_test_exe) {
                const main_test_exe = b.addTest(.{
                    .name = "ghostty-test",
                    .kind = .test_exe,
                    .root_source_file = .{ .path = "src/main.zig" },
                    .target = target,
                });
                main_test_exe.install();
            }
            main_test.setFilter(test_filter);
            _ = try addDeps(b, main_test, true);
            main_test.addOptions("build_options", exe_options);

            var before = b.addLog("\x1b[" ++ color_map.get("cyan").? ++ "\x1b[" ++ color_map.get("b").? ++ "[{s} tests]" ++ "\x1b[" ++ color_map.get("d").? ++ " ----" ++ "\x1b[0m", .{"ghostty"});
            var after = b.addLog("\x1b[" ++ color_map.get("d").? ++ "–––---\n\n" ++ "\x1b[0m", .{});
            test_step.dependOn(&before.step);
            test_step.dependOn(&main_test.step);
            test_step.dependOn(&after.step);
        }

        // Named package dependencies don't have their tests run by reference,
        // so we iterate through them here. We're only interested in dependencies
        // we wrote (are in the "pkg/" directory).
        var it = main_test.modules.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const module = entry.value_ptr.*;
            if (std.mem.eql(u8, name, "build_options")) continue;
            if (std.mem.eql(u8, name, "glfw")) continue;

            var buf: [256]u8 = undefined;
            var test_run = b.addTest(.{
                .name = try std.fmt.bufPrint(&buf, "{s}-test", .{name}),
                .kind = .@"test",
                .root_source_file = module.source_file,
                .target = target,
            });

            _ = try addDeps(b, test_run, true);
            // if (pkg.dependencies) |children| {
            //     test_.packages = std.ArrayList(std.build.Pkg).init(b.allocator);
            //     try test_.packages.appendSlice(children);
            // }

            var before = b.addLog("\x1b[" ++ color_map.get("cyan").? ++ "\x1b[" ++ color_map.get("b").? ++ "[{s} tests]" ++ "\x1b[" ++ color_map.get("d").? ++ " ----" ++ "\x1b[0m", .{name});
            var after = b.addLog("\x1b[" ++ color_map.get("d").? ++ "–––---\n\n" ++ "\x1b[0m", .{});
            test_step.dependOn(&before.step);
            test_step.dependOn(&test_run.step);
            test_step.dependOn(&after.step);

            if (emit_test_exe) {
                const test_exe = b.addTest(.{
                    .name = try std.fmt.bufPrint(&buf, "{s}-test", .{name}),
                    .kind = .test_exe,
                    .root_source_file = module.source_file,
                    .target = target,
                });
                test_exe.install();
            }
        }
    }
}

/// Used to keep track of a list of file sources.
const FileSourceList = std.ArrayList(std.build.FileSource);

/// Adds and links all of the primary dependencies for the exe.
fn addDeps(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    static: bool,
) !FileSourceList {
    var static_libs = FileSourceList.init(b.allocator);
    errdefer static_libs.deinit();

    // Wasm we do manually since it is such a different build.
    if (step.target.getCpuArch() == .wasm32) {
        // We link this package but its a no-op since Tracy
        // never actualy WORKS with wasm.
        step.addModule("tracy", tracylib.module(b));
        step.addModule("utf8proc", utf8proc.module(b));
        step.addModule("zig-js", js.module(b));

        // utf8proc
        _ = try utf8proc.link(b, step);

        return static_libs;
    }

    // If we're building a lib we have some different deps
    const lib = step.kind == .lib;

    // We always require the system SDK so that our system headers are available.
    // This makes things like `os/log.h` available for cross-compiling.
    system_sdk.include(b, step, .{});

    // We always need the Zig packages
    // TODO: This can't be the right way to use the new Zig modules system,
    // so take a closer look at this again later.
    if (font_backend.hasFontconfig()) step.addModule("fontconfig", fontconfig.module(b));
    const mod_freetype = freetype.module(b);
    const mod_macos = macos.module(b);
    step.addModule("freetype", mod_freetype);
    step.addModule("harfbuzz", harfbuzz.module(b, .{
        .freetype = mod_freetype,
        .macos = mod_macos,
    }));
    step.addModule("imgui", imgui.module(b));
    step.addModule("xev", libxev.module(b));
    step.addModule("pixman", pixman.module(b));
    step.addModule("stb_image_resize", stb_image_resize.module(b));
    step.addModule("utf8proc", utf8proc.module(b));

    // Mac Stuff
    if (step.target.isDarwin()) {
        step.addModule("objc", objc.module(b));
        step.addModule("macos", mod_macos);
        _ = try macos.link(b, step, .{});
    }

    // Tracy
    step.addModule("tracy", tracylib.module(b));
    if (tracy) {
        var tracy_step = try tracylib.link(b, step);
        system_sdk.include(b, tracy_step, .{});
    }

    // stb_image_resize
    const stb_image_resize_step = try stb_image_resize.link(b, step, .{});
    try static_libs.append(.{ .generated = &stb_image_resize_step.output_path_source });

    // utf8proc
    const utf8proc_step = try utf8proc.link(b, step);
    try static_libs.append(.{ .generated = &utf8proc_step.output_path_source });

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
        step.linkSystemLibrary("pixman-1");
        step.linkSystemLibrary("zlib");

        if (font_backend.hasFontconfig()) step.linkSystemLibrary("fontconfig");
    }

    // Other dependencies, we may dynamically link
    if (static) {
        const zlib_step = try zlib.link(b, step);
        try static_libs.append(.{ .generated = &zlib_step.output_path_source });

        const libpng_step = try libpng.link(b, step, .{
            .zlib = .{
                .step = zlib_step,
                .include = &zlib.include_paths,
            },
        });
        try static_libs.append(.{ .generated = &libpng_step.output_path_source });

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
        try static_libs.append(.{ .generated = &freetype_step.output_path_source });

        // Harfbuzz
        const harfbuzz_step = try harfbuzz.link(b, step, .{
            .freetype = .{
                .enabled = true,
                .step = freetype_step,
                .include = &freetype.include_paths,
            },

            .coretext = .{
                .enabled = font_backend.hasCoretext(),
            },
        });
        system_sdk.include(b, harfbuzz_step, .{});
        try static_libs.append(.{ .generated = &harfbuzz_step.output_path_source });

        // Pixman
        const pixman_step = try pixman.link(b, step, .{});
        try static_libs.append(.{ .generated = &pixman_step.output_path_source });

        // Only Linux gets fontconfig
        if (font_backend.hasFontconfig()) {
            // Libxml2
            const libxml2_lib = try libxml2.create(
                b,
                step.target,
                step.optimize,
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

    if (!lib) {
        // We always statically compile glad
        step.addIncludePath("vendor/glad/include/");
        step.addCSourceFile("vendor/glad/src/gl.c", &.{});

        // When we're targeting flatpak we ALWAYS link GTK so we
        // get access to glib for dbus.
        if (flatpak) {
            step.linkSystemLibrary("gtk4");
            switch (step.target.getCpuArch()) {
                .aarch64 => step.addLibraryPath("/usr/lib/aarch64-linux-gnu"),
                .x86_64 => step.addLibraryPath("/usr/lib/x86_64-linux-gnu"),
                else => @panic("unsupported flatpak target"),
            }
        }

        switch (app_runtime) {
            .none => {},

            .glfw => {
                step.addModule("glfw", glfw.module(b));
                const glfw_opts: glfw.Options = .{
                    .metal = step.target.isDarwin(),
                    .opengl = false,
                };
                try glfw.link(b, step, glfw_opts);

                // Must also link to imgui
                const imgui_step = try imgui.link(b, step, imgui_opts);
                try glfw.link(b, imgui_step, glfw_opts);
            },

            .gtk => {
                // We need glfw for GTK because we use GLFW to get DPI.
                step.addModule("glfw", glfw.module(b));
                const glfw_opts: glfw.Options = .{
                    .metal = step.target.isDarwin(),
                    .opengl = false,
                };
                try glfw.link(b, step, glfw_opts);

                step.linkSystemLibrary("gtk4");
            },
        }
    }

    return static_libs;
}

fn benchSteps(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    install: bool,
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
        const c_exe = b.addExecutable(.{
            .name = bin_name,
            .root_source_file = .{ .path = path },
            .target = target,
            .optimize = optimize,
        });
        c_exe.setMainPkgPath("./src");
        if (install) c_exe.install();
        _ = try addDeps(b, c_exe, true);
    }
}

fn conformanceSteps(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
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
        const c_exe = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = path },
            .target = target,
            .optimize = optimize,
        });
        c_exe.setOutputDir("zig-out/bin/conformance");
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
