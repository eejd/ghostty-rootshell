const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Config = @import("../config/Config.zig");

pub const Options = struct {
    _arena: ?Arena = null,
    default: bool = false,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

/// The "list-keybinds" command is used to list all the available keybinds for Ghostty.
///
/// When executed without any arguments this will list the current keybinds loaded by the config file.
/// If no config file is found or there aren't any changes to the keybinds it will print out the default ones configured for Ghostty
///
/// The "--default" argument will print out all the default keybinds configured for Ghostty
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();
    try args.parse(Options, alloc, &opts, &iter);

    if (opts.default) {
        return try listDefaultKeybinds(alloc);
    }

    return try listKeybinds(alloc);
}

fn listKeybinds(alloc: Allocator) !u8 {
    var loaded_config = try Config.load(alloc);
    defer loaded_config.deinit();

    const stdout = std.io.getStdOut().writer();
    var iter = loaded_config.keybind.set.bindings.iterator();

    return try iterConfig(&stdout, &iter);
}

fn listDefaultKeybinds(alloc: Allocator) !u8 {
    var default = try Config.default(alloc);
    defer default.deinit();

    const stdout = std.io.getStdOut().writer();
    var iter = default.keybind.set.bindings.iterator();

    return try iterConfig(&stdout, &iter);
}

fn iterConfig(stdout: anytype, iter: anytype) !u8 {
    const start = @intFromEnum(inputpkg.Key.one);
    var amount: u8 = 0;

    while (iter.next()) |next| {
        const keys = next.key_ptr.*;
        const value = next.value_ptr.*;
        try stdout.print("{s}", .{@tagName(value)});
        switch (value) {
            .goto_tab => |val| try stdout.print(" {d}:", .{val}),
            .jump_to_prompt => |val| try stdout.print(" {d}:", .{val}),
            .increase_font_size, .decrease_font_size => |val| try stdout.print(" {d}:", .{val}),
            .goto_split => |val| try stdout.print(" {s}:", .{@tagName(val)}),
            .inspector => |val| try stdout.print(" {s}:", .{@tagName(val)}),
            inline else => try stdout.print(":", .{}),
        }

        switch (keys.key) {
            .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => try stdout.print(" {d} +", .{(@intFromEnum(keys.key) - start) + 1}),
            inline else => try stdout.print(" {s} +", .{@tagName(keys.key)}),
        }
        const fields = @typeInfo(@TypeOf(keys.mods)).Struct.fields;
        inline for (fields) |field| {
            switch (field.type) {
                bool => {
                    if (@field(keys.mods, field.name)) {
                        if (amount >= 1) {
                            try stdout.print(" +", .{});
                        }
                        try stdout.print(" {s}", .{field.name});
                        amount += 1;
                    }
                },
                u6 => continue,

                inline else => {
                    try stdout.print("\n", .{});
                    continue;
                },
            }
        }

        amount = 0;
    }

    return 0;
}
