const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const internal_os = @import("os/main.zig");

const log = std.log.scoped(.passwd);

// We want to be extra sure since this will force bad symbols into our import table
comptime {
    if (builtin.target.isWasm()) {
        @compileError("passwd is not available for wasm");
    }
}

/// Used to determine the default shell and directory on Unixes.
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
});

// Entry that is retrieved from the passwd API. This only contains the fields
// we care about.
pub const Entry = struct {
    shell: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

/// Get the passwd entry for the currently executing user.
pub fn get(alloc: Allocator) !Entry {
    var buf: [1024]u8 = undefined;
    var pw: c.struct_passwd = undefined;
    var pw_ptr: ?*c.struct_passwd = null;
    const res = c.getpwuid_r(c.getuid(), &pw, &buf, buf.len, &pw_ptr);
    if (res != 0) {
        log.warn("error retrieving pw entry code={d}", .{res});
        return Entry{};
    }

    if (pw_ptr == null) {
        // Future: let's check if a better shell is available like zsh
        log.warn("no pw entry to detect default shell, will default to 'sh'", .{});
        return Entry{};
    }

    var result: Entry = .{};

    // If we're in flatpak then our entry is always empty so we grab it
    // by shelling out to the host. note that we do HAVE an entry in the
    // sandbox but only the username is correct.
    //
    // Note: we wrap our getent call in a /bin/sh login shell because
    // some operating systems (NixOS tested) don't set the PATH for various
    // utilities properly until we get a login shell.
    if (internal_os.isFlatpak()) {
        log.info("flatpak detected, will use host-spawn to get our entry", .{});
        const exec = try std.ChildProcess.exec(.{
            .allocator = alloc,
            .argv = &[_][]const u8{
                "/app/bin/host-spawn",
                "-pty",
                "/bin/sh",
                "-l",
                "-c",
                try std.fmt.allocPrint(
                    alloc,
                    "getent passwd {s}",
                    .{std.mem.sliceTo(pw.pw_name, 0)},
                ),
            },
        });
        if (exec.term == .Exited) {
            // Shell and home are the last two entries
            var it = std.mem.splitBackwards(u8, exec.stdout, ":");
            result.shell = it.next() orelse null;
            result.home = it.next() orelse null;
            return result;
        }
    }

    if (pw.pw_shell) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const sh = try alloc.alloc(u8, source.len);
        std.mem.copy(u8, sh, source);
        result.shell = sh;
    }

    if (pw.pw_dir) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const dir = try alloc.alloc(u8, source.len);
        std.mem.copy(u8, dir, source);
        result.home = dir;
    }

    return result;
}

test {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // We should be able to get an entry
    const entry = try get(alloc);
    try testing.expect(entry.shell != null);
    try testing.expect(entry.home != null);
}
