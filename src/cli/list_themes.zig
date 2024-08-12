const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Config = @import("../config/Config.zig");
const internal_os = @import("../os/main.zig");
const global_state = &@import("../global.zig").state;

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-themes` command is used to list all the available themes for
/// Ghostty.
///
/// Themes require that Ghostty have access to the resources directory. On macOS
/// this is embedded in the app bundle. On Linux, this is usually in `/usr/
/// share/ghostty`. If you're compiling from source, this is the `zig-out/share/
/// ghostty` directory. You can also set the `GHOSTTY_RESOURCES_DIR` environment
/// variable to point to the resources directory. Themes live in the `themes`
/// subdirectory of the resources directory.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    if (global_state.resources_dir == null)
        try stderr.print("Could not find the Ghostty resources directory. Please ensure " ++
            "that Ghostty is installed correctly.\n", .{});

    const paths: []const struct {
        type: Config.ThemeDirType,
        dir: ?[]const u8,
    } = &.{
        .{
            .type = .user,
            .dir = Config.themeDir(alloc, .user),
        },
        .{
            .type = .system,
            .dir = Config.themeDir(alloc, .system),
        },
    };

    const ThemeListElement = struct {
        type: Config.ThemeDirType,
        path: []const u8,
        theme: []const u8,
        fn deinit(self: *const @This(), alloc_: std.mem.Allocator) void {
            alloc_.free(self.path);
            alloc_.free(self.theme);
        }
        fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return std.ascii.orderIgnoreCase(lhs.theme, rhs.theme) == .lt;
        }
    };

    var count: usize = 0;

    var themes = std.ArrayList(ThemeListElement).init(alloc);
    defer {
        for (themes.items) |v| v.deinit(alloc);
        themes.deinit();
    }

    for (paths) |path| {
        if (path.dir) |p| {
            defer alloc.free(p);

            var dir = try std.fs.cwd().openDir(p, .{ .iterate = true });
            defer dir.close();

            var walker = try dir.walk(alloc);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                if (entry.kind != .file) continue;
                count += 1;
                try themes.append(.{
                    .type = path.type,
                    .path = try std.fs.path.join(alloc, &.{ p, entry.basename }),
                    .theme = try alloc.dupe(u8, entry.basename),
                });
            }
        }
    }

    std.mem.sortUnstable(ThemeListElement, themes.items, {}, ThemeListElement.lessThan);

    for (themes.items) |theme| {
        try stdout.print("{s} ({s})\n", .{ theme.theme, @tagName(theme.type) });
    }

    if (count == 0) {
        try stderr.print("No themes found, check to make sure that the themes were installed correctly.", .{});
        return 1;
    }

    return 0;
}
