const std = @import("std");
const Allocator = std.mem.Allocator;
const cftype = @import("type.zig");

pub const String = opaque {
    pub fn createWithBytes(
        bs: []const u8,
        encoding: StringEncoding,
        external: bool,
    ) Allocator.Error!*String {
        return CFStringCreateWithBytes(
            null,
            bs.ptr,
            bs.len,
            @enumToInt(encoding),
            external,
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *String) void {
        cftype.CFRelease(self);
    }

    pub fn hasPrefix(self: *String, prefix: *String) bool {
        return CFStringHasPrefix(self, prefix) == 1;
    }

    pub extern "c" fn CFStringCreateWithBytes(
        allocator: ?*anyopaque,
        bytes: [*]const u8,
        numBytes: usize,
        encooding: u32,
        is_external: bool,
    ) ?*String;
    pub extern "c" fn CFStringHasPrefix(*String, *String) u8;
};

/// https://developer.apple.com/documentation/corefoundation/cfstringencoding?language=objc
pub const StringEncoding = enum(u32) {
    invalid = 0xffffffff,
    mac_roman = 0,
    windows_latin1 = 0x0500,
    iso_latin1 = 0x0201,
    nextstep_latin = 0x0B01,
    ascii = 0x0600,
    unicode = 0x0100,
    utf8 = 0x08000100,
    non_lossy_ascii = 0x0BFF,
    utf16_be = 0x10000100,
    utf16_le = 0x14000100,
    utf32 = 0x0c000100,
    utf32_be = 0x18000100,
    utf32_le = 0x1c000100,
};

test "string" {
    const testing = std.testing;

    const str = try String.createWithBytes("hello world", .ascii, false);
    defer str.release();

    const prefix = try String.createWithBytes("hello", .ascii, false);
    defer prefix.release();

    try testing.expect(str.hasPrefix(prefix));
}
