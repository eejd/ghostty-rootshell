const formatter = @This();
const std = @import("std");
const Config = @import("Config.zig");

/// Returns a single entry formatter for the given field name and writer.
pub fn entryFormatter(
    name: []const u8,
    writer: anytype,
) EntryFormatter(@TypeOf(writer)) {
    return .{ .name = name, .writer = writer };
}

/// The entry formatter type for a given writer.
pub fn EntryFormatter(comptime WriterType: type) type {
    return struct {
        name: []const u8,
        writer: WriterType,

        pub fn formatEntry(
            self: @This(),
            comptime T: type,
            value: T,
        ) !void {
            return formatter.formatEntry(
                T,
                self.name,
                value,
                self.writer,
            );
        }
    };
}

/// Format a single type with the given name and value.
pub fn formatEntry(
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

        .Enum => {
            try writer.print("{s} = {s}\n", .{ name, @tagName(value) });
            return;
        },

        .Void => {
            try writer.print("{s} = \n", .{name});
            return;
        },

        .Optional => |info| {
            if (value) |inner| {
                try formatEntry(
                    info.child,
                    name,
                    inner,
                    writer,
                );
            } else {
                try writer.print("{s} = \n", .{name});
            }

            return;
        },

        .Pointer => switch (T) {
            []const u8,
            [:0]const u8,
            => {
                try writer.print("{s} = {s}\n", .{ name, value });
                return;
            },

            else => {},
        },

        // Structs of all types require a "formatEntry" function
        // to be defined which will be called to format the value.
        // This is given the formatter in use so that they can
        // call BACK to our formatEntry to write each primitive
        // value.
        .Struct => |info| if (@hasDecl(T, "formatEntry")) {
            try value.formatEntry(entryFormatter(name, writer));
            return;
        } else switch (info.layout) {
            // Packed structs we special case.
            .Packed => {
                try writer.print("{s} = ", .{name});
                inline for (info.fields, 0..) |field, i| {
                    if (i > 0) try writer.print(",", .{});
                    try writer.print("{s}{s}", .{
                        if (!@field(value, field.name)) "no-" else "",
                        field.name,
                    });
                }
                try writer.print("\n", .{});
                return;
            },

            else => {},
        },

        // TODO
        .Union => return,

        else => {},
    }

    // Compile error so that we can catch missing cases.
    @compileLog(T);
    @compileError("missing case for type");
}

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
            try formatEntry(
                field.type,
                field.name,
                @field(self.config, field.name),
                writer,
            );
        }
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

    //std.log.warn("{s}", .{buf.items});
}
