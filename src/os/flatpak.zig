const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const log = std.log.scoped(.flatpak);

/// Returns true if we're running in a Flatpak environment.
pub fn isFlatpak() bool {
    // If we're not on Linux then we'll make this comptime false.
    if (comptime builtin.os.tag != .linux) return false;
    return if (std.fs.accessAbsolute("/.flatpak-info", .{})) true else |_| false;
}

/// A struct to help execute commands on the host via the
/// org.freedesktop.Flatpak.Development DBus module.
pub const FlatpakHostCommand = struct {
    const Allocator = std.mem.Allocator;
    const fd_t = std.os.fd_t;
    const EnvMap = std.process.EnvMap;
    const c = @cImport({
        @cInclude("gio/gio.h");
        @cInclude("gio/gunixfdlist.h");
    });

    /// Argv are the arguments to call on the host with argv[0] being
    /// the command to execute.
    argv: []const []const u8,

    /// The cwd for the new process. If this is not set then it will use
    /// the current cwd of the calling process.
    cwd: ?[:0]const u8 = null,

    /// Environment variables for the child process. If this is null, this
    /// does not send any environment variables.
    env: ?*const EnvMap = null,

    /// File descriptors to send to the child process.
    stdin: StdIo = .{ .devnull = null },
    stdout: StdIo = .{ .devnull = null },
    stderr: StdIo = .{ .devnull = null },

    /// Process ID is set after spawn is called.
    pid: ?c_int = null,

    pub const StdIo = union(enum) {
        // Drop the input/output to /dev/null. The value should be NULL
        // and the spawn functil will take care of initializing and closing.
        devnull: ?fd_t,

        /// Setup the stdio to be a pipe. The value should be set to NULL
        /// to start and the spawn function will take care of initializing
        /// the pipe.
        pipe: ?fd_t,

        fn setup(self: *StdIo) !fd_t {
            switch (self.*) {
                .devnull => |*v| {
                    assert(v.* == null);

                    // Slight optimization potential: we can open /dev/null
                    // exactly once but its so rare that we use it that I
                    // didn't care to optimize this at this time.
                    const fd = std.os.openZ("/dev/null", std.os.O.RDWR, 0) catch |err| switch (err) {
                        error.PathAlreadyExists => unreachable,
                        error.NoSpaceLeft => unreachable,
                        error.FileTooBig => unreachable,
                        error.DeviceBusy => unreachable,
                        error.FileLocksNotSupported => unreachable,
                        error.BadPathName => unreachable, // Windows-only
                        error.InvalidHandle => unreachable, // WASI-only
                        error.WouldBlock => unreachable,
                        else => |e| return e,
                    };

                    v.* = fd;
                    return fd;
                },

                .pipe => unreachable,
            }
        }
    };

    /// Spawn the command. This will start the host command and set the
    /// pid field on success. This will not wait for completion.
    pub fn spawn(self: *FlatpakHostCommand, alloc: Allocator) !void {
        var arena_allocator = std.heap.ArenaAllocator.init(alloc);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        var err: [*c]c.GError = null;
        const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse {
            log.warn("spawn error getting bus: {s}", .{err.*.message});
            return error.FlatpakDbusFailed;
        };
        defer c.g_object_unref(bus);

        // Our list of file descriptors that we need to send to the process.
        const fd_list = c.g_unix_fd_list_new();
        defer c.g_object_unref(fd_list);

        // Build our arguments for the file descriptors.
        const fd_builder = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{uh}"));
        defer c.g_variant_builder_unref(fd_builder);
        try setupFd(&self.stdin, 0, fd_list, fd_builder);
        try setupFd(&self.stdout, 1, fd_list, fd_builder);
        try setupFd(&self.stderr, 2, fd_list, fd_builder);

        // Build our env vars
        const env_builder = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{ss}"));
        defer c.g_variant_builder_unref(env_builder);
        if (self.env) |env| {
            var it = env.iterator();
            while (it.next()) |pair| {
                const key = try arena.dupeZ(u8, pair.key_ptr.*);
                const value = try arena.dupeZ(u8, pair.value_ptr.*);
                c.g_variant_builder_add(env_builder, "{ss}", key.ptr, value.ptr);
            }
        }

        // Build our args
        const args_ptr = c.g_ptr_array_new();
        {
            errdefer _ = c.g_ptr_array_free(args_ptr, 1);
            for (self.argv) |arg| {
                const argZ = try arena.dupeZ(u8, arg);
                c.g_ptr_array_add(args_ptr, argZ.ptr);
            }
        }
        const args = c.g_ptr_array_free(args_ptr, 0);
        defer c.g_free(@ptrCast(?*anyopaque, args));

        // Get the cwd in case we don't have ours set. A small optimization
        // would be to do this only if we need it but this isn't a
        // common code path.
        const g_cwd = c.g_get_current_dir();
        defer c.g_free(g_cwd);

        // The params for our RPC call
        const params = c.g_variant_new(
            "(^ay^aay@a{uh}@a{ss}u)",
            if (self.cwd) |cwd| cwd.ptr else g_cwd,
            args,
            c.g_variant_builder_end(fd_builder),
            c.g_variant_builder_end(env_builder),
            @as(c_int, 0),
        );
        _ = c.g_variant_ref_sink(params); // take ownership
        defer c.g_variant_unref(params);

        // Go!
        const reply = c.g_dbus_connection_call_with_unix_fd_list_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommand",
            params,
            c.G_VARIANT_TYPE("(u)"),
            c.G_DBUS_CALL_FLAGS_NONE,
            c.G_MAXINT,
            fd_list,
            null,
            null,
            &err,
        ) orelse {
            log.warn("Flatpak.HostCommand failed: {s}", .{err.*.message});
            return error.FlatpakHostCommandFailed;
        };
        defer c.g_variant_unref(reply);

        var pid: c_int = 0;
        c.g_variant_get(reply, "(u)", &pid);
        log.debug("HostCommand started pid={}", .{pid});

        self.pid = pid;
    }

    /// Helper to setup our io fd and add it to the necessary fd
    /// list for sending to the child and parameter list for calling our
    /// API.
    fn setupFd(
        stdio: *StdIo,
        child_fd: fd_t,
        list: *c.GUnixFDList,
        builder: *c.GVariantBuilder,
    ) !void {
        const fd = try stdio.setup();

        var err: [*c]c.GError = null;
        if (c.g_unix_fd_list_append(list, fd, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.*.message});
            return error.FlatpakFdFailed;
        }

        c.g_variant_builder_add(builder, "{uh}", child_fd, fd);
    }
};
