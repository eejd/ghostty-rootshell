const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const objc = @import("objc");
const Allocator = std.mem.Allocator;

pub const NSOperatingSystemVersion = extern struct {
    major: i64,
    minor: i64,
    patch: i64,
};

/// Verifies that the running macOS system version is at least the given version.
pub fn isAtLeastVersion(major: i64, minor: i64, patch: i64) bool {
    assert(builtin.target.isDarwin());

    const NSProcessInfo = objc.getClass("NSProcessInfo").?;
    const info = NSProcessInfo.msgSend(objc.Object, objc.sel("processInfo"), .{});
    return info.msgSend(bool, objc.sel("isOperatingSystemAtLeastVersion:"), .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

pub const NSSearchPathDirectory = enum(c_ulong) {
    NSApplicationSupportDirectory = 14,
};

pub const NSSearchPathDomainMask = enum(c_ulong) {
    NSUserDomainMask = 1,
};

pub fn getAppSupportDir(alloc: Allocator, sub_path: []const u8) ![]u8 {
    assert(builtin.target.isDarwin());

    const err: ?*anyopaque = undefined;
    const NSFileManager = objc.getClass("NSFileManager").?;
    const manager = NSFileManager.msgSend(objc.Object, objc.sel("defaultManager"), .{});
    const url = manager.msgSend(
        objc.Object,
        objc.sel("URLForDirectory:inDomain:appropriateForURL:create:error:"),
        .{
            NSSearchPathDirectory.NSApplicationSupportDirectory,
            NSSearchPathDomainMask.NSUserDomainMask,
            @as(?*anyopaque, null),
            true,
            &err,
        },
    );
    const path = url.getProperty(objc.Object, "path");
    const c_str = path.getProperty([*:0]const u8, "UTF8String");
    const app_support_dir = std.mem.sliceTo(c_str, 0);

    return try std.fs.path.join(alloc, &.{ app_support_dir, "com.mitchellh.ghostty", sub_path });
}
