const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

/// Open the configuration in the OS default editor according to the default
/// paths the main config file could be in.
pub fn open(alloc_gpa: Allocator) !void {
    // default dir
    const config_dir = try internal_os.xdg.config(alloc_gpa, .{ .subdir = "ghostty" });
    // default location
    const config_path = try internal_os.xdg.config(alloc_gpa, .{ .subdir = "ghostty/config" });

    defer {
        alloc_gpa.free(config_path);
        alloc_gpa.free(config_dir);
    }

    // Check if the directory exists, create it if it doesn't
    _ = std.fs.makeDirAbsolute(config_dir) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    // Try to create file and go on if it already exists
    _ = std.fs.createFileAbsolute(
        config_path,
        .{ .exclusive = true },
    ) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    try internal_os.open(alloc_gpa, config_path);
}
