const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const assert = std.debug.assert;
const objc = @import("objc");
const Allocator = std.mem.Allocator;

/// Verifies that the running macOS system version is at least the given version.
pub fn isAtLeastVersion(major: i64, minor: i64, patch: i64) bool {
    comptime assert(builtin.target.isDarwin());

    const NSProcessInfo = objc.getClass("NSProcessInfo").?;
    const info = NSProcessInfo.msgSend(objc.Object, objc.sel("processInfo"), .{});
    return info.msgSend(bool, objc.sel("isOperatingSystemAtLeastVersion:"), .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

pub const AppSupportDirError = Allocator.Error || error{AppleAPIFailed};

/// Return the path to the application support directory for Ghostty
/// with the given sub path joined. This allocates the result using the
/// given allocator.
pub fn appSupportDir(
    alloc: Allocator,
    sub_path: []const u8,
) AppSupportDirError![]u8 {
    comptime assert(builtin.target.isDarwin());

    const NSFileManager = objc.getClass("NSFileManager").?;
    const manager = NSFileManager.msgSend(
        objc.Object,
        objc.sel("defaultManager"),
        .{},
    );

    const url = manager.msgSend(
        objc.Object,
        objc.sel("URLForDirectory:inDomain:appropriateForURL:create:error:"),
        .{
            NSSearchPathDirectory.NSApplicationSupportDirectory,
            NSSearchPathDomainMask.NSUserDomainMask,
            @as(?*anyopaque, null),
            true,
            @as(?*anyopaque, null),
        },
    );

    // I don't think this is possible but just in case.
    if (url.value == null) return error.AppleAPIFailed;

    // Get the UTF-8 string from the URL.
    const path = url.getProperty(objc.Object, "path");
    const c_str = path.getProperty(?[*:0]const u8, "UTF8String") orelse
        return error.AppleAPIFailed;
    const app_support_dir = std.mem.sliceTo(c_str, 0);

    return try std.fs.path.join(alloc, &.{
        app_support_dir,
        build_config.bundle_id,
        sub_path,
    });
}

pub const NSOperatingSystemVersion = extern struct {
    major: i64,
    minor: i64,
    patch: i64,
};

pub const NSSearchPathDirectory = enum(c_ulong) {
    NSApplicationSupportDirectory = 14,
};

pub const NSSearchPathDomainMask = enum(c_ulong) {
    NSUserDomainMask = 1,
};
