const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const args = @import("args.zig");
const font = @import("../font/main.zig");

const log = std.log.scoped(.list_fonts);

pub const Config = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

pub fn run(alloc: Allocator) !u8 {
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    var config: Config = .{};
    defer config.deinit();
    try args.parse(Config, alloc_gpa, &config, argsIter);

    // Use an arena for all our memory allocs
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Its possible to build Ghostty without font discovery!
    if (comptime font.Discover == void) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print(
            \\Ghostty was built without a font discovery mechanism. This is a compile-time
            \\option. Please review how Ghostty was built from source, contact the
            \\maintainer to enable a font discovery mechanism, and try again.
        ,
            .{},
        );
        return 1;
    }

    const stdout = std.io.getStdOut().writer();

    // We'll be putting our fonts into a list categorized by family
    // so it is easier to read the output.
    var families = std.ArrayList([]const u8).init(alloc);
    var map = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(alloc);

    // Look up all available fonts
    var disco = font.Discover.init();
    defer disco.deinit();
    var disco_it = try disco.discover(.{});
    defer disco_it.deinit();
    while (try disco_it.next()) |face| {
        var buf: [1024]u8 = undefined;

        const family_buf = face.familyName(&buf) catch |err| {
            log.err("failed to get font family name: {}", .{err});
            continue;
        };
        const family = try alloc.dupe(u8, family_buf);

        const full_name_buf = face.name(&buf) catch |err| {
            log.err("failed to get font name: {}", .{err});
            continue;
        };
        const full_name = try alloc.dupe(u8, full_name_buf);

        const gop = try map.getOrPut(family);
        if (!gop.found_existing) {
            try families.append(family);
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(alloc, full_name);
    }

    // Sort our keys.
    std.mem.sortUnstable([]const u8, families.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    // Output each
    for (families.items) |family| {
        const list = map.get(family) orelse continue;
        if (list.items.len == 0) continue;
        std.mem.sortUnstable([]const u8, list.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);

        try stdout.print("{s}\n", .{family});
        for (list.items) |item| try stdout.print("  {s}\n", .{item});
        try stdout.print("\n", .{});
    }

    return 0;
}
