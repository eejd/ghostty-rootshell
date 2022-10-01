const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const Dictionary = opaque {
    pub fn create(
        keys: ?[]?*const anyopaque,
        values: ?[]?*const anyopaque,
    ) Allocator.Error!*Dictionary {
        if (keys != null or values != null) {
            assert(keys != null);
            assert(values != null);
            assert(keys.?.len == values.?.len);
        }

        return @intToPtr(?*Dictionary, @ptrToInt(c.CFDictionaryCreate(
            null,
            @ptrCast([*c]?*const anyopaque, if (keys) |slice| slice.ptr else null),
            @ptrCast([*c]?*const anyopaque, if (values) |slice| slice.ptr else null),
            @intCast(c.CFIndex, if (keys) |slice| slice.len else 0),
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        ))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Dictionary) void {
        foundation.CFRelease(self);
    }

    pub fn getCount(self: *Dictionary) usize {
        return @intCast(usize, c.CFDictionaryGetCount(@ptrCast(c.CFDictionaryRef, self)));
    }

    pub fn getValue(self: *Dictionary, comptime V: type, key: ?*const anyopaque) ?*V {
        return @intToPtr(?*V, @ptrToInt(c.CFDictionaryGetValue(
            @ptrCast(c.CFDictionaryRef, self),
            key,
        )));
    }
};

test "dictionary" {
    const testing = std.testing;

    const str = try foundation.String.createWithBytes("hello", .unicode, false);
    defer str.release();

    var keys = [_]?*const anyopaque{c.kCFURLIsPurgeableKey};
    var values = [_]?*const anyopaque{str};
    const dict = try Dictionary.create(&keys, &values);
    defer dict.release();

    try testing.expectEqual(@as(usize, 1), dict.getCount());
    try testing.expect(dict.getValue(foundation.String, c.kCFURLIsPurgeableKey) != null);
    try testing.expect(dict.getValue(foundation.String, c.kCFURLIsVolumeKey) == null);
}
