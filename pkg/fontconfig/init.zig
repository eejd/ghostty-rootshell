const std = @import("std");
const c = @import("c.zig");
const Config = @import("config.zig").Config;

pub fn init() bool {
    return c.FcInit() == c.FcTrue;
}

pub fn fini() void {
    c.FcFini();
}

pub fn initLoadConfig() *Config {
    return @ptrCast(*Config, c.FcInitLoadConfig());
}

pub fn initLoadConfigAndFonts() *Config {
    return @ptrCast(*Config, c.FcInitLoadConfigAndFonts());
}

pub fn version() u32 {
    return @intCast(u32, c.FcGetVersion());
}

test "version" {
    const testing = std.testing;
    try testing.expect(version() > 0);
}

test "init" {
    try std.testing.expect(init());
    defer fini();
}

test "initLoadConfig" {
    var config = initLoadConfig();
    defer config.destroy();
}

test "initLoadConfigAndFonts" {
    var config = initLoadConfigAndFonts();
    defer config.destroy();
}
