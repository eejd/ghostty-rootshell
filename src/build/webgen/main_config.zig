const std = @import("std");
const Config = @import("../../config/Config.zig");
const help_strings = @import("help_strings");

pub fn main() !void {
    const output = std.io.getStdOut().writer();
    try genConfig(output);
}

pub fn genConfig(writer: anytype) !void {
    // Write the header
    try writer.writeAll(
        \\---
        \\title: Reference
        \\description: Reference of all Ghostty configuration options.
        \\---
        \\
        \\This is a reference of all Ghostty configuration options. These
        \\options are ordered roughly by how common they are to be used
        \\and grouped with related options. I recommend utilizing your
        \\browser's search functionality to find the option you're looking
        \\for.
        \\
        \\In the future, we'll have a more user-friendly way to view and
        \\organize these options.
        \\
        \\
    );

    @setEvalBranchQuota(3000);
    const fields = @typeInfo(Config).Struct.fields;
    inline for (fields, 0..) |field, i| {
        if (field.name[0] == '_') continue;
        if (!@hasDecl(help_strings.Config, field.name)) continue;

        // Write the field name.
        try writer.writeAll("## `");
        try writer.writeAll(field.name);
        try writer.writeAll("`\n");

        // For all subsequent fields with no docs, they are grouped
        // with the previous field.
        if (i + 1 < fields.len) {
            inline for (fields[i + 1 ..]) |next_field| {
                if (next_field.name[0] == '_') break;
                if (@hasDecl(help_strings.Config, next_field.name)) break;

                try writer.writeAll("## `");
                try writer.writeAll(next_field.name);
                try writer.writeAll("`\n");
            }
        }

        // Newline after our headers
        try writer.writeAll("\n");

        var iter = std.mem.splitScalar(
            u8,
            @field(help_strings.Config, field.name),
            '\n',
        );

        // We do some really rough markdown "parsing" here so that
        // we can fix up some styles for what our website expects.
        var block: ?enum {
            /// Plaintext, do nothing.
            text,

            /// Code block, wrap in triple backticks. We use indented
            /// code blocks in our comments but the website parser only
            /// supports triple backticks.
            code,
        } = null;

        while (iter.next()) |s| {
            // Empty line resets our block
            if (std.mem.eql(u8, s, "")) {
                if (block) |v| switch (v) {
                    .text => {},
                    .code => try writer.writeAll("```\n"),
                };
                block = null;

                try writer.writeAll("\n");
                continue;
            }

            // If we don't have a block figure out our type.
            if (block == null) {
                if (std.mem.startsWith(u8, s, "    ")) {
                    block = .code;
                    try writer.writeAll("```\n");
                } else {
                    block = .text;
                }
            }

            try writer.writeAll(switch (block.?) {
                .text => s,
                .code => if (std.mem.startsWith(u8, s, "    "))
                    s[4..]
                else
                    s,
            });
            try writer.writeAll("\n");
        }
        try writer.writeAll("\n");
    }
}
