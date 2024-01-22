const std = @import("std");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const KeybindAction = @import("../input/Binding.zig").Action;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const help_strings = @import("help_strings");

pub const Options = struct {
    /// If true, print out the default keybinds instead of the ones
    /// configured in the config file.
    default: bool = false,

    docs: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-keybinds` command is used to list all the available keybinds for
/// Ghostty.
///
/// When executed without any arguments this will list the current keybinds
/// loaded by the config file. If no config file is found or there aren't any
/// changes to the keybinds it will print out the default ones configured for
/// Ghostty
///
/// The `--default` argument will print out all the default keybinds configured
/// for Ghostty
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var config = if (opts.default) try Config.default(alloc) else try Config.load(alloc);
    defer config.deinit();

    const stdout = std.io.getStdOut().writer();
    if (opts.docs) {
        const info = @typeInfo(KeybindAction);
        var first = true;
        inline for (info.Union.fields) |field| {
            if (field.name[0] == '_') continue;
            if (@hasDecl(help_strings.KeybindAction, field.name)) {
                if (!first) try stdout.print("#\n", .{});
                try stdout.print("# {s}\n", .{field.name});
                const help = @field(help_strings.KeybindAction, field.name);
                var lines = std.mem.splitScalar(u8, help, '\n');
                while (lines.next()) |line| {
                    try stdout.print("#   {s}\n", .{line});
                }
                first = false;
            }
        }
    }

    try config.keybind.formatEntry(configpkg.entryFormatter("keybind", stdout));

    return 0;
}
