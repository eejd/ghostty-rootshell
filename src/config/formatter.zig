const std = @import("std");
const Config = @import("Config.zig");

/// FileFormatter is a formatter implementation that outputs the
/// config in a file-like format. This uses more generous whitespace,
/// can include comments, etc.
pub const FileFormatter = struct {
    config: *const Config,

    /// Implements std.fmt so it can be used directly with std.fmt.
    pub fn format(
        self: FileFormatter,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;

        inline for (@typeInfo(Config).Struct.fields) |field| {
            if (field.name[0] == '_') continue;
            try self.formatField(
                field.type,
                field.name,
                @field(self.config, field.name),
                writer,
            );
        }
    }

    fn formatField(
        self: FileFormatter,
        comptime T: type,
        name: []const u8,
        value: T,
        writer: anytype,
    ) !void {
        switch (@typeInfo(T)) {
            .Bool, .Int => {
                try writer.print("{s} = {}\n", .{ name, value });
                return;
            },

            .Float => {
                try writer.print("{s} = {d}\n", .{ name, value });
                return;
            },

            .Optional => |info| if (value) |inner| {
                try self.formatField(
                    info.child,
                    name,
                    inner,
                    writer,
                );
            } else {
                try writer.print("{s} = \n", .{name});
            },

            .Pointer => switch (T) {
                []const u8,
                [:0]const u8,
                => {
                    try writer.print("{s} = {s}\n", .{ name, value });
                },

                else => {},
            },

            else => {},
        }

        // TODO: make a compiler error so we can detect when
        // we don't support a type.
    }
};

test "format default config" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const fmt: FileFormatter = .{ .config = &cfg };
    try std.fmt.format(buf.writer(), "{}", .{fmt});

    std.log.warn("{s}", .{buf.items});
}
