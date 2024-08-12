const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const global_state = &@import("../main.zig").state;
const internal_os = @import("../os/main.zig");
const ErrorList = @import("ErrorList.zig");

/// Location of possible themes. The order of this enum matters because
/// it defines the priority of theme search (from top to bottom).
pub const Location = enum {
    user, // xdg config dir
    resources, // Ghostty resources dir

    /// Returns the directory for the given theme based on this location type.
    ///
    /// This will return null with no error if the directory type doesn't
    /// exist or is invalid for any reason. For example, it is perfectly
    /// valid to install and run Ghostty without the resources directory.
    ///
    /// This may allocate memory but it isn't guaranteed so the allocator
    /// should be something like an arena. It isn't safe to always free the
    /// resulting pointer.
    pub fn dir(
        self: Location,
        alloc_arena: Allocator,
        theme: []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        if (comptime std.debug.runtime_safety) {
            assert(!std.fs.path.isAbsolute(theme));
        }

        return switch (self) {
            .user => user: {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const subdir = std.fmt.bufPrint(
                    &buf,
                    "ghostty/themes/{s}",
                    .{theme},
                ) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutOfMemory,
                };

                break :user internal_os.xdg.config(
                    alloc_arena,
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

            .resources => try std.fs.path.join(alloc_arena, &.{
                global_state.resources_dir orelse return null,
                "themes",
                theme,
            }),
        };
    }
};

/// An iterator that returns all possible locations for a theme in order
/// of priority.
pub const LocationIterator = struct {
    alloc_arena: Allocator,
    theme: []const u8,
    i: usize = 0,

    pub fn next(self: *LocationIterator) !?[]const u8 {
        const max = @typeInfo(Location).Enum.fields.len;
        while (true) {
            if (self.i >= max) return null;
            const loc: Location = @enumFromInt(self.i);
            self.i += 1;
            const dir_ = try loc.dir(self.alloc_arena, self.theme);
            const dir = dir_ orelse continue;
            return dir;
        }
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
pub fn open(
    alloc_arena: Allocator,
    theme: []const u8,
    errors: *ErrorList,
) error{OutOfMemory}!?std.fs.File {
    // Absolute themes are loaded a different path.
    if (std.fs.path.isAbsolute(theme)) return try openAbsolute(
        alloc_arena,
        theme,
        errors,
    );

    // Iterate over the possible locations to try to find the
    // one that exists.
    var it: LocationIterator = .{ .alloc_arena = alloc_arena, .theme = theme };
    const cwd = std.fs.cwd();
    while (try it.next()) |path| {
        if (cwd.openFile(path, .{})) |file| {
            return file;
        } else |err| switch (err) {
            // Not an error, just continue to the next location.
            error.FileNotFound => {},

            // Anything else is an error we log and give up on.
            else => {
                try errors.add(alloc_arena, .{
                    .message = try std.fmt.allocPrintZ(
                        alloc_arena,
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
    while (try it.next()) |path| {
        try errors.add(alloc_arena, .{
            .message = try std.fmt.allocPrintZ(
                alloc_arena,
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
pub fn openAbsolute(
    alloc_arena: Allocator,
    theme: []const u8,
    errors: *ErrorList,
) error{OutOfMemory}!?std.fs.File {
    return std.fs.openFileAbsolute(theme, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => try errors.add(alloc_arena, .{
                .message = try std.fmt.allocPrintZ(
                    alloc_arena,
                    "failed to load theme from the path \"{s}\"",
                    .{theme},
                ),
            }),
            else => try errors.add(alloc_arena, .{
                .message = try std.fmt.allocPrintZ(
                    alloc_arena,
                    "failed to load theme from the path \"{s}\": {}",
                    .{ theme, err },
                ),
            }),
        }

        return null;
    };
}
