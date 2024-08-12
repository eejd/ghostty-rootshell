const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const global_state = &@import("../main.zig").state;
const internal_os = @import("../os/main.zig");
const ErrorList = @import("ErrorList.zig");

/// Location of possible themes. The order of this enum matters because it
/// defines the priority of theme search (from top to bottom).
pub const Location = enum {
    user, // XDG config dir
    resources, // Ghostty resources dir

    /// Returns the directory for the given theme based on this location type.
    ///
    /// This will return null with no error if the directory type doesn't exist
    /// or is invalid for any reason. For example, it is perfectly valid to
    /// install and run Ghostty without the resources directory.
    ///
    /// Due to the way allocations are handled, a pointer to an Arena allocator
    /// must be used.
    pub fn dir(
        self: Location,
        arena: *ArenaAllocator,
    ) error{OutOfMemory}!?[]const u8 {
        const alloc = arena.allocator();

        // if (comptime std.debug.runtime_safety) {
        //     assert(!std.fs.path.isAbsolute(theme));
        // }

        return switch (self) {
            .user => user: {
                const subdir = std.fs.path.join(alloc, &.{
                    "ghostty", "themes",
                }) catch return error.OutOfMemory;

                break :user internal_os.xdg.config(
                    alloc,
                    .{ .subdir = subdir },
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BufferTooSmall => return error.OutOfMemory,

                    // Any other error we treat as the XDG directory not
                    // existing. Windows in particularly can return a LOT
                    // of errors here.
                    else => return null,
                };
            },

            .resources => try std.fs.path.join(alloc, &.{
                global_state.resources_dir orelse return null,
                "themes",
            }),
        };
    }
};

/// An iterator that returns all possible directories for finding themes in
/// order of priority.
pub const LocationIterator = struct {
    arena: *ArenaAllocator,
    i: usize = 0,

    pub fn next(self: *LocationIterator) !?struct {
        location: Location,
        dir: []const u8,
    } {
        const max = @typeInfo(Location).Enum.fields.len;
        std.debug.print("a: {d} {d}\n", .{ self.i, max });
        while (self.i < max) {
            std.debug.print("b: {d}\n", .{self.i});
            const location: Location = @enumFromInt(self.i);
            self.i += 1;
            if (try location.dir(self.arena)) |dir|
                return .{
                    .location = location,
                    .dir = dir,
                };
        }
        return null;
    }

    pub fn reset(self: *LocationIterator) void {
        self.i = 0;
    }
};

/// Open the given named theme. If there are any errors then messages
/// will be appended to the given error list and null is returned. If
/// a non-null return value is returned, there are never any errors added.
///
/// One error that is not recoverable and may be returned is OOM. This is
/// always a critical error for configuration loading so it is returned.
///
/// Due to the way allocations are handled, a pointer to an Arena allocator
/// must be used.
pub fn open(
    arena: *ArenaAllocator,
    theme: []const u8,
    errors: *ErrorList,
) error{OutOfMemory}!?std.fs.File {

    // Absolute themes are loaded a different path.
    if (std.fs.path.isAbsolute(theme)) return try openAbsolute(
        arena,
        theme,
        errors,
    );

    const alloc = arena.allocator();

    const basename = std.fs.path.basename(theme);
    if (!std.mem.eql(u8, theme, basename)) {
        try errors.add(alloc, .{
            .message = try std.fmt.allocPrintZ(
                alloc,
                "theme \"{s}\" cannot include path separators unless it is an absolute path",
                .{theme},
            ),
        });
        return null;
    }

    // Iterate over the possible locations to try to find the
    // one that exists.
    var it: LocationIterator = .{ .arena = arena };
    const cwd = std.fs.cwd();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(alloc, &.{ loc.dir, theme });
        if (cwd.openFile(path, .{})) |file| {
            return file;
        } else |err| switch (err) {
            // Not an error, just continue to the next location.
            error.FileNotFound => {},

            // Anything else is an error we log and give up on.
            else => {
                try errors.add(alloc, .{
                    .message = try std.fmt.allocPrintZ(
                        alloc,
                        "failed to load theme \"{s}\" from the file \"{s}\": {}",
                        .{ theme, path, err },
                    ),
                });

                return null;
            },
        }
    }

    // Unlikely scenario: the theme doesn't exist. In this case, we reset
    // our iterator, reiterate over in order to build a better error message.
    // This does double allocate some memory but for errors I think thats
    // fine.
    it.reset();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(alloc, &.{ loc.dir, theme });
        try errors.add(alloc, .{
            .message = try std.fmt.allocPrintZ(
                alloc,
                "theme \"{s}\" not found, tried path \"{s}\"",
                .{ theme, path },
            ),
        });
    }

    return null;
}

/// Open the given theme from an absolute path. If there are any errors
/// then messages will be appended to the given error list and null is
/// returned. If a non-null return value is returned, there are never any
/// errors added.
///
/// Due to the way allocations are handled, a pointer to an Arena allocator
/// must be used.
pub fn openAbsolute(
    arena: *ArenaAllocator,
    theme: []const u8,
    errors: *ErrorList,
) error{OutOfMemory}!?std.fs.File {
    const alloc = arena.allocator();
    return std.fs.openFileAbsolute(theme, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => try errors.add(alloc, .{
                .message = try std.fmt.allocPrintZ(
                    alloc,
                    "failed to load theme from the path \"{s}\"",
                    .{theme},
                ),
            }),
            else => try errors.add(alloc, .{
                .message = try std.fmt.allocPrintZ(
                    alloc,
                    "failed to load theme from the path \"{s}\": {}",
                    .{ theme, err },
                ),
            }),
        }

        return null;
    };
}
