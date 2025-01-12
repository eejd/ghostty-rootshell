const std = @import("std");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");
const KeybindAction = @import("../input/Binding.zig").Action;

pub const Options = struct {
    /// If `true`, print out documentation about the action associated with the
    /// keybinds.
    docs: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-actions` command is used to list all the available keybind
/// actions for Ghostty. These are distinct from the CLI Actions which can
/// be listed via `+help`
///
/// The `--docs` argument will print out the documentation for each action.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();

    var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buffer.deinit();

    const fields = @typeInfo(KeybindAction).Union.fields;
    inline for (fields) |field| {
        if (field.name[0] == '_') continue;

        // Write previously stored doc comment below all related actions
        if (@hasDecl(help_strings.KeybindAction, field.name)) {
            try stdout.writeAll(buffer.items);
            try stdout.writeAll("\n");

            buffer.clearRetainingCapacity();
        }

        // Write the field name.
        try stdout.writeAll(field.name);
        try stdout.writeAll(":\n");

        if (@hasDecl(help_strings.KeybindAction, field.name)) {
            var iter = std.mem.splitScalar(
                u8,
                @field(help_strings.KeybindAction, field.name),
                '\n',
            );
            while (iter.next()) |s| {
                // If it is the last line and empty, then skip it.
                if (iter.peek() == null and s.len == 0) continue;
                try buffer.appendSlice("  ");
                try buffer.appendSlice(s);
                try buffer.appendSlice("\n");
            }
        }
    }

    // Write any remaining buffered documentation
    if (buffer.items.len > 0) {
        try stdout.writeAll(buffer.items);
    }

    return 0;
}
