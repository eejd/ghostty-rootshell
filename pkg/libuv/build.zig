const std = @import("std");

/// Directories with our includes.
const root = thisDir() ++ "../../../vendor/libuv/";
const include_path = root ++ "include";

pub const pkg = std.build.Pkg{
    .name = "libuv",
    .source = .{ .path = thisDir() ++ "/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn link(b: *std.build.Builder, step: *std.build.LibExeObjStep) !*std.build.LibExeObjStep {
    const libuv = try buildLibuv(b, step);
    step.linkLibrary(libuv);
    step.addIncludePath(include_path);
    return libuv;
}

pub fn buildLibuv(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
) !*std.build.LibExeObjStep {
    const lib = b.addStaticLibrary("uv", null);
    lib.setTarget(step.target);
    lib.setBuildMode(step.build_mode);

    const target = step.target;

    // Include dirs
    lib.addIncludePath(include_path);
    lib.addIncludePath(root ++ "src");

    // Links
    if (target.isWindows()) {
        lib.linkSystemLibrary("psapi");
        lib.linkSystemLibrary("user32");
        lib.linkSystemLibrary("advapi32");
        lib.linkSystemLibrary("iphlpapi");
        lib.linkSystemLibrary("userenv");
        lib.linkSystemLibrary("ws2_32");
    }
    if (target.isLinux()) {
        lib.linkSystemLibrary("pthread");
    }
    lib.linkLibC();

    // Compilation
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    // try flags.appendSlice(&.{});

    if (!target.isWindows()) {
        try flags.appendSlice(&.{
            "-D_FILE_OFFSET_BITS=64",
            "-D_LARGEFILE_SOURCE",
        });
    }

    if (target.isLinux()) {
        try flags.appendSlice(&.{
            "-D_GNU_SOURCE",
            "-D_POSIX_C_SOURCE=200112",
        });
    }

    if (target.isDarwin()) {
        try flags.appendSlice(&.{
            "-D_DARWIN_UNLIMITED_SELECT=1",
            "-D_DARWIN_USE_64_BIT_INODE=1",
        });
    }

    // C files common to all platforms
    lib.addCSourceFiles(&.{
        root ++ "src/fs-poll.c",
        root ++ "src/idna.c",
        root ++ "src/inet.c",
        root ++ "src/random.c",
        root ++ "src/strscpy.c",
        root ++ "src/strtok.c",
        root ++ "src/threadpool.c",
        root ++ "src/timer.c",
        root ++ "src/uv-common.c",
        root ++ "src/uv-data-getter-setters.c",
        root ++ "src/version.c",
    }, flags.items);

    if (!target.isWindows()) {
        lib.addCSourceFiles(&.{
            root ++ "src/unix/async.c",
            root ++ "src/unix/core.c",
            root ++ "src/unix/dl.c",
            root ++ "src/unix/fs.c",
            root ++ "src/unix/getaddrinfo.c",
            root ++ "src/unix/getnameinfo.c",
            root ++ "src/unix/loop-watcher.c",
            root ++ "src/unix/loop.c",
            root ++ "src/unix/pipe.c",
            root ++ "src/unix/poll.c",
            root ++ "src/unix/process.c",
            root ++ "src/unix/random-devurandom.c",
            root ++ "src/unix/signal.c",
            root ++ "src/unix/stream.c",
            root ++ "src/unix/tcp.c",
            root ++ "src/unix/thread.c",
            root ++ "src/unix/tty.c",
            root ++ "src/unix/udp.c",
        }, flags.items);
    }

    if (target.isLinux() or target.isDarwin()) {
        lib.addCSourceFiles(&.{
            root ++ "src/unix/proctitle.c",
        }, flags.items);
    }

    if (target.isLinux()) {
        lib.addCSourceFiles(&.{
            root ++ "src/unix/linux-core.c",
            root ++ "src/unix/linux-inotify.c",
            root ++ "src/unix/linux-syscalls.c",
            root ++ "src/unix/procfs-exepath.c",
            root ++ "src/unix/random-getrandom.c",
            root ++ "src/unix/random-sysctl-linux.c",
            root ++ "src/unix/epoll.c",
        }, flags.items);
    }

    if (target.isDarwin() or
        target.isOpenBSD() or
        target.isNetBSD() or
        target.isFreeBSD() or
        target.isDragonFlyBSD())
    {
        lib.addCSourceFiles(&.{
            root ++ "src/unix/bsd-ifaddrs.c",
            root ++ "src/unix/kqueue.c",
        }, flags.items);
    }

    if (target.isDarwin() or target.isOpenBSD()) {
        lib.addCSourceFiles(&.{
            root ++ "src/unix/random-getentropy.c",
        }, flags.items);
    }

    if (target.isDarwin()) {
        lib.addCSourceFiles(&.{
            root ++ "src/unix/darwin-proctitle.c",
            root ++ "src/unix/darwin.c",
            root ++ "src/unix/fsevents.c",
        }, flags.items);
    }

    return lib;
}
