//! Exec implements the logic for starting and stopping a subprocess with a
//! pty as well as spinning up the necessary read thread to read from the
//! pty and forward it to the Termio instance.
const Exec = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const xev = @import("xev");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const shell_integration = @import("shell_integration.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const SegmentedPool = @import("../segmented_pool.zig").SegmentedPool;
const Pty = @import("../pty.zig").Pty;
const EnvMap = std.process.EnvMap;
const windows = internal_os.windows;

const log = std.log.scoped(.io_exec);

/// If we build with flatpak support then we have to keep track of
/// a potential execution on the host.
const FlatpakHostCommand = if (build_config.flatpak) internal_os.FlatpakHostCommand else void;

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

arena: std.heap.ArenaAllocator,
cwd: ?[]const u8,
env: EnvMap,
args: [][]const u8,
grid_size: renderer.GridSize,
screen_size: renderer.ScreenSize,
pty: ?Pty = null,
command: ?Command = null,
flatpak_command: ?FlatpakHostCommand = null,
linux_cgroup: Command.LinuxCgroup = Command.linux_cgroup_default,

/// Initialize the subprocess. This will NOT start it, this only sets
/// up the internal state necessary to start it later.
pub fn init(gpa: Allocator, opts: termio.Options) !Exec {
    // We have a lot of maybe-allocations that all share the same lifetime
    // so use an arena so we don't end up in an accounting nightmare.
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Set our env vars. For Flatpak builds running in Flatpak we don't
    // inherit our environment because the login shell on the host side
    // will get it.
    var env = env: {
        if (comptime build_config.flatpak) {
            if (internal_os.isFlatpak()) {
                break :env std.process.EnvMap.init(alloc);
            }
        }

        break :env try std.process.getEnvMap(alloc);
    };
    errdefer env.deinit();

    // If we have a resources dir then set our env var
    if (opts.resources_dir) |dir| {
        log.info("found Ghostty resources dir: {s}", .{dir});
        try env.put("GHOSTTY_RESOURCES_DIR", dir);
    }

    // Set our TERM var. This is a bit complicated because we want to use
    // the ghostty TERM value but we want to only do that if we have
    // ghostty in the TERMINFO database.
    //
    // For now, we just look up a bundled dir but in the future we should
    // also load the terminfo database and look for it.
    if (opts.resources_dir) |base| {
        try env.put("TERM", opts.config.term);
        try env.put("COLORTERM", "truecolor");

        // Assume that the resources directory is adjacent to the terminfo
        // database
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const dir = try std.fmt.bufPrint(&buf, "{s}/terminfo", .{
            std.fs.path.dirname(base) orelse unreachable,
        });
        try env.put("TERMINFO", dir);
    } else {
        if (comptime builtin.target.isDarwin()) {
            log.warn("ghostty terminfo not found, using xterm-256color", .{});
            log.warn("the terminfo SHOULD exist on macos, please ensure", .{});
            log.warn("you're using a valid app bundle.", .{});
        }

        try env.put("TERM", "xterm-256color");
        try env.put("COLORTERM", "truecolor");
    }

    // Add our binary to the path if we can find it.
    ghostty_path: {
        var exe_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const exe_bin_path = std.fs.selfExePath(&exe_buf) catch |err| {
            log.warn("failed to get ghostty exe path err={}", .{err});
            break :ghostty_path;
        };
        const exe_dir = std.fs.path.dirname(exe_bin_path) orelse break :ghostty_path;
        log.debug("appending ghostty bin to path dir={s}", .{exe_dir});

        // We always set this so that if the shell overwrites the path
        // scripts still have a way to find the Ghostty binary when
        // running in Ghostty.
        try env.put("GHOSTTY_BIN_DIR", exe_dir);

        // Append if we have a path. We want to append so that ghostty is
        // the last priority in the path. If we don't have a path set
        // then we just set it to the directory of the binary.
        if (env.get("PATH")) |path| {
            // Verify that our path doesn't already contain this entry
            var it = std.mem.tokenizeScalar(u8, path, internal_os.PATH_SEP[0]);
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry, exe_dir)) break :ghostty_path;
            }

            try env.put(
                "PATH",
                try internal_os.appendEnv(alloc, path, exe_dir),
            );
        } else {
            try env.put("PATH", exe_dir);
        }
    }

    // Add the man pages from our application bundle to MANPATH.
    if (comptime builtin.target.isDarwin()) {
        if (opts.resources_dir) |resources_dir| man: {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const dir = std.fmt.bufPrint(&buf, "{s}/../man", .{resources_dir}) catch |err| {
                log.warn("error building manpath, man pages may not be available err={}", .{err});
                break :man;
            };

            if (env.get("MANPATH")) |manpath| {
                // Append to the existing MANPATH. It's very unlikely that our bundle's
                // resources directory already appears here so we don't spend the time
                // searching for it.
                try env.put(
                    "MANPATH",
                    try internal_os.appendEnv(alloc, manpath, dir),
                );
            } else {
                try env.put("MANPATH", dir);
            }
        }
    }

    // Set environment variables used by some programs (such as neovim) to detect
    // which terminal emulator and version they're running under.
    try env.put("TERM_PROGRAM", "ghostty");
    try env.put("TERM_PROGRAM_VERSION", build_config.version_string);

    // When embedding in macOS and running via XCode, XCode injects
    // a bunch of things that break our shell process. We remove those.
    if (comptime builtin.target.isDarwin() and build_config.artifact == .lib) {
        if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
            env.remove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
            env.remove("__XPC_DYLD_LIBRARY_PATH");
            env.remove("DYLD_FRAMEWORK_PATH");
            env.remove("DYLD_INSERT_LIBRARIES");
            env.remove("DYLD_LIBRARY_PATH");
            env.remove("LD_LIBRARY_PATH");
            env.remove("SECURITYSESSIONID");
            env.remove("XPC_SERVICE_NAME");
        }

        // Remove this so that running `ghostty` within Ghostty works.
        env.remove("GHOSTTY_MAC_APP");
    }

    // Don't leak these environment variables to child processes.
    if (comptime build_config.app_runtime == .gtk) {
        env.remove("GDK_DEBUG");
        env.remove("GSK_RENDERER");
    }

    // Setup our shell integration, if we can.
    const integrated_shell: ?shell_integration.Shell, const shell_command: []const u8 = shell: {
        const default_shell_command = opts.full_config.command orelse switch (builtin.os.tag) {
            .windows => "cmd.exe",
            else => "sh",
        };

        const force: ?shell_integration.Shell = switch (opts.full_config.@"shell-integration") {
            .none => break :shell .{ null, default_shell_command },
            .detect => null,
            .bash => .bash,
            .elvish => .elvish,
            .fish => .fish,
            .zsh => .zsh,
        };

        const dir = opts.resources_dir orelse break :shell .{
            null,
            default_shell_command,
        };

        const integration = try shell_integration.setup(
            alloc,
            dir,
            default_shell_command,
            &env,
            force,
            opts.full_config.@"shell-integration-features",
        ) orelse break :shell .{ null, default_shell_command };

        break :shell .{ integration.shell, integration.command };
    };

    if (integrated_shell) |shell| {
        log.info(
            "shell integration automatically injected shell={}",
            .{shell},
        );
    } else if (opts.full_config.@"shell-integration" != .none) {
        log.warn("shell could not be detected, no automatic shell integration will be injected", .{});
    }

    // Build our args list
    const args = args: {
        const cap = 9; // the most we'll ever use
        var args = try std.ArrayList([]const u8).initCapacity(alloc, cap);
        defer args.deinit();

        // If we're on macOS, we have to use `login(1)` to get all of
        // the proper environment variables set, a login shell, and proper
        // hushlogin behavior.
        if (comptime builtin.target.isDarwin()) darwin: {
            const passwd = internal_os.passwd.get(alloc) catch |err| {
                log.warn("failed to read passwd, not using a login shell err={}", .{err});
                break :darwin;
            };

            const username = passwd.name orelse {
                log.warn("failed to get username, not using a login shell", .{});
                break :darwin;
            };

            const hush = if (passwd.home) |home| hush: {
                var dir = std.fs.openDirAbsolute(home, .{}) catch |err| {
                    log.warn(
                        "failed to open home dir, not checking for hushlogin err={}",
                        .{err},
                    );
                    break :hush false;
                };
                defer dir.close();

                break :hush if (dir.access(".hushlogin", .{})) true else |_| false;
            } else false;

            const cmd = try std.fmt.allocPrint(
                alloc,
                "exec -l {s}",
                .{shell_command},
            );

            // The reason for executing login this way is unclear. This
            // comment will attempt to explain but prepare for a truly
            // unhinged reality.
            //
            // The first major issue is that on macOS, a lot of users
            // put shell configurations in ~/.bash_profile instead of
            // ~/.bashrc (or equivalent for another shell). This file is only
            // loaded for a login shell so macOS users expect all their terminals
            // to be login shells. No other platform behaves this way and its
            // totally braindead but somehow the entire dev community on
            // macOS has cargo culted their way to this reality so we have to
            // do it...
            //
            // To get a login shell, you COULD just prepend argv0 with a `-`
            // but that doesn't fully work because `getlogin()` C API will
            // return the wrong value, SHELL won't be set, and various
            // other login behaviors that macOS users expect.
            //
            // The proper way is to use `login(1)`. But login(1) forces
            // the working directory to change to the home directory,
            // which we may not want. If we specify "-l" then we can avoid
            // this behavior but now the shell isn't a login shell.
            //
            // There is another issue: `login(1)` only checks for ".hushlogin"
            // in the working directory. This means that if we specify "-l"
            // then we won't get hushlogin honored if its in the home
            // directory (which is standard). To get around this, we
            // check for hushlogin ourselves and if present specify the
            // "-q" flag to login(1).
            //
            // So to get all the behaviors we want, we specify "-l" but
            // execute "bash" (which is built-in to macOS). We then use
            // the bash builtin "exec" to replace the process with a login
            // shell ("-l" on exec) with the command we really want.
            //
            // We use "bash" instead of other shells that ship with macOS
            // because as of macOS Sonoma, we found with a microbenchmark
            // that bash can `exec` into the desired command ~2x faster
            // than zsh.
            //
            // To figure out a lot of this logic I read the login.c
            // source code in the OSS distribution Apple provides for
            // macOS.
            //
            // Awesome.
            try args.append("/usr/bin/login");
            if (hush) try args.append("-q");
            try args.append("-flp");

            // We execute bash with "--noprofile --norc" so that it doesn't
            // load startup files so that (1) our shell integration doesn't
            // break and (2) user configuration doesn't mess this process
            // up.
            try args.append(username);
            try args.append("/bin/bash");
            try args.append("--noprofile");
            try args.append("--norc");
            try args.append("-c");
            try args.append(cmd);
            break :args try args.toOwnedSlice();
        }

        if (comptime builtin.os.tag == .windows) {
            // We run our shell wrapped in `cmd.exe` so that we don't have
            // to parse the command line ourselves if it has arguments.

            // Note we don't free any of the memory below since it is
            // allocated in the arena.
            const windir = try std.process.getEnvVarOwned(alloc, "WINDIR");
            const cmd = try std.fs.path.join(alloc, &[_][]const u8{
                windir,
                "System32",
                "cmd.exe",
            });

            try args.append(cmd);
            try args.append("/C");
        } else {
            // We run our shell wrapped in `/bin/sh` so that we don't have
            // to parse the command line ourselves if it has arguments.
            // Additionally, some environments (NixOS, I found) use /bin/sh
            // to setup some environment variables that are important to
            // have set.
            try args.append("/bin/sh");
            if (internal_os.isFlatpak()) try args.append("-l");
            try args.append("-c");
        }

        try args.append(shell_command);
        break :args try args.toOwnedSlice();
    };

    // We have to copy the cwd because there is no guarantee that
    // pointers in full_config remain valid.
    const cwd: ?[]u8 = if (opts.full_config.@"working-directory") |cwd|
        try alloc.dupe(u8, cwd)
    else
        null;

    // If we have a cgroup, then we copy that into our arena so the
    // memory remains valid when we start.
    const linux_cgroup: Command.LinuxCgroup = cgroup: {
        const default = Command.linux_cgroup_default;
        if (comptime builtin.os.tag != .linux) break :cgroup default;
        const path = opts.linux_cgroup orelse break :cgroup default;
        break :cgroup try alloc.dupe(u8, path);
    };

    // Our screen size should be our padded size
    const padded_size = opts.screen_size.subPadding(opts.padding);

    return .{
        .arena = arena,
        .env = env,
        .cwd = cwd,
        .args = args,
        .grid_size = opts.grid_size,
        .screen_size = padded_size,
        .linux_cgroup = linux_cgroup,
    };
}

/// Clean up the subprocess. This will stop the subprocess if it is started.
pub fn deinit(self: *Exec) void {
    self.stop();
    if (self.pty) |*pty| pty.deinit();
    self.arena.deinit();
    self.* = undefined;
}

/// Start the subprocess. If the subprocess is already started this
/// will crash.
pub fn start(self: *Exec, alloc: Allocator) !struct {
    read: Pty.Fd,
    write: Pty.Fd,
} {
    assert(self.pty == null and self.command == null);

    // Create our pty
    var pty = try Pty.open(.{
        .ws_row = @intCast(self.grid_size.rows),
        .ws_col = @intCast(self.grid_size.columns),
        .ws_xpixel = @intCast(self.screen_size.width),
        .ws_ypixel = @intCast(self.screen_size.height),
    });
    self.pty = pty;
    errdefer {
        pty.deinit();
        self.pty = null;
    }

    log.debug("starting command command={s}", .{self.args});

    // In flatpak, we use the HostCommand to execute our shell.
    if (internal_os.isFlatpak()) flatpak: {
        if (comptime !build_config.flatpak) {
            log.warn("flatpak detected, but flatpak support not built-in", .{});
            break :flatpak;
        }

        // Flatpak command must have a stable pointer.
        self.flatpak_command = .{
            .argv = self.args,
            .env = &self.env,
            .stdin = pty.slave,
            .stdout = pty.slave,
            .stderr = pty.slave,
        };
        var cmd = &self.flatpak_command.?;
        const pid = try cmd.spawn(alloc);
        errdefer killCommandFlatpak(cmd);

        log.info("started subcommand on host via flatpak API path={s} pid={?}", .{
            self.args[0],
            pid,
        });

        // Once started, we can close the pty child side. We do this after
        // wait right now but that is fine too. This lets us read the
        // parent and detect EOF.
        _ = posix.close(pty.slave);

        return .{
            .read = pty.master,
            .write = pty.master,
        };
    }

    // If we can't access the cwd, then don't set any cwd and inherit.
    // This is important because our cwd can be set by the shell (OSC 7)
    // and we don't want to break new windows.
    const cwd: ?[]const u8 = if (self.cwd) |proposed| cwd: {
        if (std.fs.accessAbsolute(proposed, .{})) {
            break :cwd proposed;
        } else |err| {
            log.warn("cannot access cwd, ignoring: {}", .{err});
            break :cwd null;
        }
    } else null;

    // Build our subcommand
    var cmd: Command = .{
        .path = self.args[0],
        .args = self.args,
        .env = &self.env,
        .cwd = cwd,
        .stdin = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
        .stdout = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
        .stderr = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
        .pseudo_console = if (builtin.os.tag == .windows) pty.pseudo_console else {},
        .pre_exec = if (builtin.os.tag == .windows) null else (struct {
            fn callback(cmd: *Command) void {
                const sp = cmd.getData(Exec) orelse unreachable;
                sp.childPreExec() catch |err| log.err(
                    "error initializing child: {}",
                    .{err},
                );
            }
        }).callback,
        .data = self,
        .linux_cgroup = self.linux_cgroup,
    };
    try cmd.start(alloc);
    errdefer killCommand(&cmd) catch |err| {
        log.warn("error killing command during cleanup err={}", .{err});
    };
    log.info("started subcommand path={s} pid={?}", .{ self.args[0], cmd.pid });
    if (comptime builtin.os.tag == .linux) {
        log.info("subcommand cgroup={s}", .{self.linux_cgroup orelse "-"});
    }

    self.command = cmd;
    return switch (builtin.os.tag) {
        .windows => .{
            .read = pty.out_pipe,
            .write = pty.in_pipe,
        },

        else => .{
            .read = pty.master,
            .write = pty.master,
        },
    };
}

/// This should be called after fork but before exec in the child process.
/// To repeat: this function RUNS IN THE FORKED CHILD PROCESS before
/// exec is called; it does NOT run in the main Ghostty process.
fn childPreExec(self: *Exec) !void {
    // Setup our pty
    try self.pty.?.childPreExec();
}

/// Called to notify that we exited externally so we can unset our
/// running state.
pub fn externalExit(self: *Exec) void {
    self.command = null;
}

/// Stop the subprocess. This is safe to call anytime. This will wait
/// for the subprocess to register that it has been signalled, but not
/// for it to terminate, so it will not block.
/// This does not close the pty.
pub fn stop(self: *Exec) void {
    // Kill our command
    if (self.command) |*cmd| {
        // Note: this will also wait for the command to exit, so
        // DO NOT call cmd.wait
        killCommand(cmd) catch |err|
            log.err("error sending SIGHUP to command, may hang: {}", .{err});
        self.command = null;
    }

    // Kill our Flatpak command
    if (FlatpakHostCommand != void) {
        if (self.flatpak_command) |*cmd| {
            killCommandFlatpak(cmd) catch |err|
                log.err("error sending SIGHUP to command, may hang: {}", .{err});
            _ = cmd.wait() catch |err|
                log.err("error waiting for command to exit: {}", .{err});
            self.flatpak_command = null;
        }
    }
}

/// Resize the pty subprocess. This is safe to call anytime.
pub fn resize(
    self: *Exec,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;

    if (self.pty) |*pty| {
        try pty.setSize(.{
            .ws_row = @intCast(grid_size.rows),
            .ws_col = @intCast(grid_size.columns),
            .ws_xpixel = @intCast(screen_size.width),
            .ws_ypixel = @intCast(screen_size.height),
        });
    }
}

/// Kill the underlying subprocess. This sends a SIGHUP to the child
/// process. This also waits for the command to exit and will return the
/// exit code.
fn killCommand(command: *Command) !void {
    if (command.pid) |pid| {
        switch (builtin.os.tag) {
            .windows => {
                if (windows.kernel32.TerminateProcess(pid, 0) == 0) {
                    return windows.unexpectedError(windows.kernel32.GetLastError());
                }

                _ = try command.wait(false);
            },

            else => if (getpgid(pid)) |pgid| {
                // It is possible to send a killpg between the time that
                // our child process calls setsid but before or simultaneous
                // to calling execve. In this case, the direct child dies
                // but grandchildren survive. To work around this, we loop
                // and repeatedly kill the process group until all
                // descendents are well and truly dead. We will not rest
                // until the entire family tree is obliterated.
                while (true) {
                    if (c.killpg(pgid, c.SIGHUP) < 0) {
                        log.warn("error killing process group pgid={}", .{pgid});
                        return error.KillFailed;
                    }

                    // See Command.zig wait for why we specify WNOHANG.
                    // The gist is that it lets us detect when children
                    // are still alive without blocking so that we can
                    // kill them again.
                    const res = posix.waitpid(pid, std.c.W.NOHANG);
                    if (res.pid != 0) break;
                    std.time.sleep(10 * std.time.ns_per_ms);
                }
            },
        }
    }
}

fn getpgid(pid: c.pid_t) ?c.pid_t {
    // Get our process group ID. Before the child pid calls setsid
    // the pgid will be ours because we forked it. Its possible that
    // we may be calling this before setsid if we are killing a surface
    // VERY quickly after starting it.
    const my_pgid = c.getpgid(0);

    // We loop while pgid == my_pgid. The expectation if we have a valid
    // pid is that setsid will eventually be called because it is the
    // FIRST thing the child process does and as far as I can tell,
    // setsid cannot fail. I'm sure that's not true, but I'd rather
    // have a bug reported than defensively program against it now.
    while (true) {
        const pgid = c.getpgid(pid);
        if (pgid == my_pgid) {
            log.warn("pgid is our own, retrying", .{});
            std.time.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        // Don't know why it would be zero but its not a valid pid
        if (pgid == 0) return null;

        // If the pid doesn't exist then... we're done!
        if (pgid == c.ESRCH) return null;

        // If we have an error we're done.
        if (pgid < 0) {
            log.warn("error getting pgid for kill", .{});
            return null;
        }

        return pgid;
    }
}

/// Kill the underlying process started via Flatpak host command.
/// This sends a signal via the Flatpak API.
fn killCommandFlatpak(command: *FlatpakHostCommand) !void {
    try command.signal(c.SIGHUP, true);
}
