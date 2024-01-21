const std = @import("std");
const Config = @import("../../config/Config.zig");
const Action = @import("../../cli/action.zig").Action;
const help_strings = @import("help_strings");
const build_options = @import("build_options");

pub fn substitute(alloc: std.mem.Allocator, input: []const u8, writer: anytype) !void {
    const version_string = try std.fmt.allocPrint(alloc, "{}", .{build_options.version});

    const output = try alloc.alloc(u8, std.mem.replacementSize(u8, input, "@@VERSION@@", version_string));
    defer alloc.free(output);
    _ = std.mem.replace(u8, input, "@@VERSION@@", version_string, output);
    try writer.writeAll(output);
}

pub fn generate_config(writer: anytype, cli: bool) !void {
    try writer.writeAll(
        \\
        \\# CONFIGURATION OPTIONS
        \\
        \\
    );

    const info = @typeInfo(Config);
    std.debug.assert(info == .Struct);

    inline for (info.Struct.fields) |field| {
        if (field.name[0] == '_') continue;

        try writer.writeAll("`");
        if (cli) try writer.writeAll("--");
        try writer.writeAll(field.name);
        try writer.writeAll("`\n\n");
        if (@hasDecl(help_strings.Config, field.name)) {
            var iter = std.mem.splitScalar(u8, @field(help_strings.Config, field.name), '\n');
            var first = true;
            while (iter.next()) |s| {
                try writer.writeAll(if (first) ":   " else "    ");
                try writer.writeAll(s);
                try writer.writeAll("\n");
                first = false;
            }
            try writer.writeAll("\n\n");
        }
    }
}

pub fn generate_actions(writer: anytype) !void {
    try writer.writeAll(
        \\
        \\# COMMAND LINE ACTIONS
        \\
        \\
    );

    const info = @typeInfo(Action);
    std.debug.assert(info == .Enum);

    inline for (info.Enum.fields) |field| {
        if (field.name[0] == '_') continue;

        const action = std.meta.stringToEnum(Action, field.name).?;

        switch (action) {
            .help => try writer.writeAll("`--help`\n\n"),
            .version => try writer.writeAll("`--version`\n\n"),
            else => {
                try writer.writeAll("`+");
                try writer.writeAll(field.name);
                try writer.writeAll("`\n\n");
            },
        }

        if (@hasDecl(help_strings.Action, field.name)) {
            var iter = std.mem.splitScalar(u8, @field(help_strings.Action, field.name), '\n');
            var first = true;
            while (iter.next()) |s| {
                try writer.writeAll(if (first) ":   " else "    ");
                try writer.writeAll(s);
                try writer.writeAll("\n");
                first = false;
            }
            try writer.writeAll("\n\n");
        }
    }
}
