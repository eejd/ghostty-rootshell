const std = @import("std");
const rgb = @embedFile("rgb");

const RGB = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    const alloc = arena.allocator();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var set = std.StringHashMap(RGB).init(alloc);
    defer set.deinit();
    var list = std.ArrayList([]const u8).init(alloc);
    defer list.deinit();

    try stdout.writeAll(
        \\// THIS FILE IS AUTO-GENERATED! DO NOT MAKE ANY CHANGES!
        \\
        \\const std = @import("std");
        \\
        \\pub const RGB = struct {
        \\    r: u8,
        \\    g: u8,
        \\    b: u8,
        \\};
        \\
        \\/// RGB color names, taken from the X11 rgb.txt file.
        \\pub const RGBName = enum {
        \\
        \\    const Self = @This();
        \\
        \\
    );

    var iter = std.mem.splitScalar(u8, rgb, '\n');
    while (iter.next()) |line| {
        if (line.len < 12) continue;
        const r = try std.fmt.parseInt(u8, std.mem.trim(u8, line[0..3], &std.ascii.whitespace), 10);
        const g = try std.fmt.parseInt(u8, std.mem.trim(u8, line[4..7], &std.ascii.whitespace), 10);
        const b = try std.fmt.parseInt(u8, std.mem.trim(u8, line[8..11], &std.ascii.whitespace), 10);
        var n = try alloc.alloc(u8, line[12..].len);
        defer alloc.free(n);
        var i: usize = 0;
        for (line[12..]) |c| {
            if (std.ascii.isWhitespace(c)) continue;
            n[i] = std.ascii.toLower(c);
            i += 1;
        }
        const m = try alloc.dupe(u8, n[0..i]);
        if (set.get(m) == null) {
            try set.put(m, RGB{ .r = r, .g = g, .b = b });
            try list.append(m);
            try stdout.print("    {s},\n", .{
                m,
            });
        }
    }

    try stdout.writeAll(
        \\
        \\    pub fn fromString(str: []const u8) ?Self {
        \\        const max = 64;
        \\        var n: [max]u8 = undefined;
        \\        var i: usize = 0;
        \\        for (str, 0..) |c, j| {
        \\           if (std.ascii.isWhitespace(c)) continue;
        \\           n[i] = std.ascii.toLower(c);
        \\           i += 1;
        \\           if (i == max) {
        \\             if (j >= str.len - 1) std.log.warn("color name '{s}' longer than {d} characters", .{str, max});
        \\             break;
        \\           }
        \\        }
        \\        return std.meta.stringToEnum(Self, n[0..i]);
        \\    }
        \\
        \\    pub fn toRGB(self: Self) RGB {
        \\       return switch(self) {
        \\
    );

    for (list.items) |name| {
        if (set.get(name)) |value| {
            try stdout.print("            .{s} => RGB{{ .r = {d}, .g = {d}, .b = {d} }},\n", .{ name, value.r, value.g, value.b });
        }
    }

    try stdout.writeAll(
        \\        };
        \\    }
        \\};
        \\
        \\test "RGBName" {
        \\    try std.testing.expectEqual(null, RGBName.fromString("nosuchcolor"));
        \\    try std.testing.expectEqual(RGBName.white, RGBName.fromString("white"));
        \\    try std.testing.expectEqual(RGBName.mediumspringgreen, RGBName.fromString("medium spring green"));
        \\    try std.testing.expectEqual(RGBName.forestgreen, RGBName.fromString("ForestGreen"));
        \\
        \\    try std.testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, RGBName.black.toRGB());
        \\    try std.testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, RGBName.red.toRGB());
        \\    try std.testing.expectEqual(RGB{ .r = 0, .g = 255, .b = 0 }, RGBName.green.toRGB());
        \\    try std.testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 255 }, RGBName.blue.toRGB());
        \\    try std.testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, RGBName.white.toRGB());
        \\    try std.testing.expectEqual(RGB{ .r = 124, .g = 252, .b = 0 }, RGBName.lawngreen.toRGB());
        \\    try std.testing.expectEqual(RGB{ .r = 0, .g = 250, .b = 154 }, RGBName.mediumspringgreen.toRGB());
        \\    try std.testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, RGBName.forestgreen.toRGB());
        \\}
        \\
    );

    try bw.flush();
}
