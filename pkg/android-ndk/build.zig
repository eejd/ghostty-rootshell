const std = @import("std");
const builtin = @import("builtin");

pub fn build(_: *std.Build) !void {}

// Configure the step to point to the Android NDK for libc and include
// paths. This requires the Android NDK installed in the system and
// setting the appropriate environment variables or installing the NDK
// in the default location.
//
// The environment variables can be set as follows:
// - `ANDROID_NDK_HOME`: Directly points to the NDK path, including the version.
// - `ANDROID_HOME` or `ANDROID_SDK_ROOT`: Points to the Android SDK path;
//   latest available NDK will be automatically selected.
//
// NB: This is a workaround until zig natively supports bionic
// cross-compilation (ziglang/zig#23906).
pub fn addPaths(b: *std.Build, step: *std.Build.Step.Compile) !void {
    const Cache = struct {
        const Key = struct {
            arch: std.Target.Cpu.Arch,
            abi: std.Target.Abi,
            api_level: u32,
        };

        var map: std.AutoHashMapUnmanaged(Key, ?struct {
            libc: std.Build.LazyPath,
            cpp_include: []const u8,
            lib: []const u8,
        }) = .{};
    };

    const target = step.rootModuleTarget();
    const gop = try Cache.map.getOrPut(b.allocator, .{
        .arch = target.cpu.arch,
        .abi = target.abi,
        .api_level = target.os.version_range.linux.android,
    });

    if (!gop.found_existing) {
        const ndk_path = findNDKPath(b.allocator) orelse {
            gop.value_ptr.* = null;
            return error.AndroidNDKNotFound;
        };

        var ndk_dir = std.fs.openDirAbsolute(ndk_path, .{}) catch {
            gop.value_ptr.* = null;
            return error.AndroidNDKNotFound;
        };
        defer ndk_dir.close();

        const ndk_triple = ndkTriple(target) orelse {
            gop.value_ptr.* = null;
            return error.AndroidNDKUnsupportedTarget;
        };

        const host = hostTag() orelse {
            gop.value_ptr.* = null;
            return error.AndroidNDKUnsupportedHost;
        };

        const sysroot = try std.fs.path.join(b.allocator, &.{
            ndk_path, "toolchains", "llvm", "prebuilt", host, "sysroot",
        });
        const include_dir = try std.fs.path.join(
            b.allocator,
            &.{ sysroot, "usr", "include" },
        );
        const sys_include_dir = try std.fs.path.join(
            b.allocator,
            &.{ sysroot, "usr", "include", ndk_triple },
        );

        var api_buf: [10]u8 = undefined;
        const api_level = target.os.version_range.linux.android;
        const api_level_str = std.fmt.bufPrint(&api_buf, "{d}", .{api_level}) catch unreachable;
        const c_runtime_dir = try std.fs.path.join(
            b.allocator,
            &.{ sysroot, "usr", "lib", ndk_triple, api_level_str },
        );

        const libc_txt = try std.fmt.allocPrint(b.allocator,
            \\include_dir={s}
            \\sys_include_dir={s}
            \\crt_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\gcc_dir=
        , .{ include_dir, sys_include_dir, c_runtime_dir });

        const wf = b.addWriteFiles();
        const libc_path = wf.add("libc.txt", libc_txt);
        const lib = try std.fs.path.join(b.allocator, &.{ sysroot, "usr", "lib", ndk_triple });
        const cpp_include = try std.fs.path.join(b.allocator, &.{ sysroot, "usr", "include", "c++", "v1" });

        gop.value_ptr.* = .{
            .lib = lib,
            .libc = libc_path,
            .cpp_include = cpp_include,
        };
    }

    const value = gop.value_ptr.* orelse return error.AndroidNDKNotFound;

    step.setLibCFile(value.libc);
    step.root_module.addSystemIncludePath(.{ .cwd_relative = value.cpp_include });
    step.root_module.addLibraryPath(.{ .cwd_relative = value.lib });
}

fn findNDKPath(allocator: std.mem.Allocator) ?[]const u8 {
    // Check if user has set the environment variable for the NDK path.
    if (std.process.getEnvVarOwned(allocator, "ANDROID_NDK_HOME") catch null) |value| {
        if (value.len > 0) return value;
    }

    // Check the common environment variables for the Android SDK path and look for the NDK inside it.
    inline for (.{ "ANDROID_HOME", "ANDROID_SDK_ROOT" }) |env| {
        if (std.process.getEnvVarOwned(allocator, env) catch null) |sdk| {
            if (sdk.len > 0) {
                if (findLatestNDK(allocator, sdk)) |ndk| return ndk;
            }
        }
    }

    // As a fallback, we assume the most common/default SDK path based on the OS.
    const home = std.process.getEnvVarOwned(
        allocator,
        if (builtin.os.tag == .windows) "LOCALAPPDATA" else "HOME",
    ) catch return null;

    const default_sdk_path = std.fs.path.join(allocator, &.{
        home, switch (builtin.os.tag) {
            .linux => "Android/sdk",
            .macos => "Library/Android/Sdk",
            .windows => "Android/Sdk",
            else => return null,
        },
    }) catch return null;
    return findLatestNDK(allocator, default_sdk_path);
}

fn findLatestNDK(allocator: std.mem.Allocator, sdk_path: []const u8) ?[]const u8 {
    const ndk_dir = std.fs.path.join(allocator, &.{ sdk_path, "ndk" }) catch return null;
    var dir = std.fs.openDirAbsolute(ndk_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var latest_version: ?[]const u8 = null;
    var latest_parsed: ?std.SemanticVersion = null;
    var iterator = dir.iterate();

    while (iterator.next() catch null) |file| {
        if (file.kind != .directory) continue;
        const parsed = std.SemanticVersion.parse(file.name) catch continue;
        if (latest_version == null or parsed.order(latest_parsed.?) == .gt) {
            if (latest_version) |old| allocator.free(old);
            latest_version = allocator.dupe(u8, file.name) catch return null;
            latest_parsed = parsed;
        }
    }

    if (latest_version) |version| {
        return std.fs.path.join(allocator, &.{ sdk_path, "ndk", version }) catch return null;
    }

    return null;
}

fn hostTag() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        // All darwin hosts use the same prebuilt binaries
        // (https://developer.android.com/ndk/guides/other_build_systems).
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => null,
    };
}

// We must map the target architecture to the corresponding NDK triple following the NDK
// documentation: https://android.googlesource.com/platform/ndk/+/master/docs/BuildSystemMaintainers.md#architectures
fn ndkTriple(target: std.Target) ?[]const u8 {
    return switch (target.cpu.arch) {
        .arm => "arm-linux-androideabi",
        .aarch64 => "aarch64-linux-android",
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        else => null,
    };
}
