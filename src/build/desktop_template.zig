const std = @import("std");
const cfg = @import("cfg");

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();

    const alloc = debug.allocator();

    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();
    var input = stdin.reader();

    while (try input.readUntilDelimiterOrEofAlloc(alloc, '\n', 4096)) |line| {
        defer alloc.free(line);

        const buf1 = try std.mem.replaceOwned(u8, alloc, line, "@@APPID@@", cfg.app_id);
        defer alloc.free(buf1);

        const buf2 = try std.mem.replaceOwned(u8, alloc, buf1, "@@NAME@@", cfg.name);
        defer alloc.free(buf2);

        const buf3 = try std.mem.replaceOwned(u8, alloc, buf2, "@@GHOSTTY@@", cfg.ghostty);
        defer alloc.free(buf3);

        if (cfg.flatpak and std.mem.startsWith(u8, buf3, "SystemdService=")) continue;

        try stdout.writeAll(buf3);
        try stdout.writeAll("\n");
    }
}
