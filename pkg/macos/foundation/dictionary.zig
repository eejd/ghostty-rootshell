const std = @import("std");
const Allocator = std.mem.Allocator;
const cftype = @import("type.zig");

pub const Dictionary = opaque {
    pub fn create() Allocator.Error!*Dictionary {
        return CFDictionaryCreate(
            null,
            null,
            null,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Dictionary) void {
        cftype.CFRelease(self);
    }

    pub extern "c" fn CFDictionaryCreate(
        allocator: ?*anyopaque,
        keys: ?[*]*const anyopaque,
        values: ?[*]*const anyopaque,
        num_values: usize,
        key_callbacks: *const anyopaque,
        value_callbacks: *const anyopaque,
    ) ?*Dictionary;

    extern "c" var kCFTypeDictionaryKeyCallBacks: anyopaque;
    extern "c" var kCFTypeDictionaryValueCallBacks: anyopaque;
};

test "dictionary" {
    const dict = try Dictionary.create();
    defer dict.release();
}
