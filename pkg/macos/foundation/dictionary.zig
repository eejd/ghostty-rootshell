const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");

pub const Dictionary = opaque {
    pub fn create(
        keys: ?[]*const anyopaque,
        values: ?[]*const anyopaque,
    ) Allocator.Error!*Dictionary {
        if (keys != null or values != null) {
            assert(keys != null);
            assert(values != null);
            assert(keys.?.len == values.?.len);
        }

        return CFDictionaryCreate(
            null,
            if (keys) |slice| slice.ptr else null,
            if (values) |slice| slice.ptr else null,
            if (keys) |slice| slice.len else 0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Dictionary) void {
        foundation.CFRelease(self);
    }

    pub fn getCount(self: *Dictionary) usize {
        return CFDictionaryGetCount(self);
    }

    pub extern "c" fn CFDictionaryCreate(
        allocator: ?*anyopaque,
        keys: ?[*]*const anyopaque,
        values: ?[*]*const anyopaque,
        num_values: usize,
        key_callbacks: *const anyopaque,
        value_callbacks: *const anyopaque,
    ) ?*Dictionary;
    pub extern "c" fn CFDictionaryGetCount(*Dictionary) usize;

    extern "c" var kCFTypeDictionaryKeyCallBacks: anyopaque;
    extern "c" var kCFTypeDictionaryValueCallBacks: anyopaque;
};

// Just used for a test
extern "c" var kCFURLIsPurgeableKey: *const anyopaque;

test "dictionary" {
    const testing = std.testing;

    const str = try foundation.String.createWithBytes("hello", .unicode, false);
    defer str.release();

    var keys = [_]*const anyopaque{kCFURLIsPurgeableKey};
    var values = [_]*const anyopaque{str};
    const dict = try Dictionary.create(&keys, &values);
    defer dict.release();

    try testing.expectEqual(@as(usize, 1), dict.getCount());
}
