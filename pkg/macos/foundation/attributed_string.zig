const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const AttributedString = opaque {
    pub fn release(self: *AttributedString) void {
        foundation.CFRelease(self);
    }

    pub fn getLength(self: *AttributedString) usize {
        return @intCast(
            usize,
            c.CFAttributedStringGetLength(@ptrCast(c.CFAttributedStringRef, self)),
        );
    }

    pub fn getString(self: *AttributedString) *foundation.String {
        return @ptrFromInt(
            *foundation.String,
            @intFromPtr(
                c.CFAttributedStringGetString(@ptrCast(c.CFAttributedStringRef, self)),
            ),
        );
    }
};

pub const MutableAttributedString = opaque {
    pub fn create(cap: usize) Allocator.Error!*MutableAttributedString {
        return @ptrFromInt(
            ?*MutableAttributedString,
            @intFromPtr(c.CFAttributedStringCreateMutable(
                null,
                @intCast(c.CFIndex, cap),
            )),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *MutableAttributedString) void {
        foundation.CFRelease(self);
    }

    pub fn replaceString(
        self: *MutableAttributedString,
        range: foundation.Range,
        replacement: *foundation.String,
    ) void {
        c.CFAttributedStringReplaceString(
            @ptrCast(c.CFMutableAttributedStringRef, self),
            range.cval(),
            @ptrCast(c.CFStringRef, replacement),
        );
    }

    pub fn setAttribute(
        self: *MutableAttributedString,
        range: foundation.Range,
        key: anytype,
        value: ?*anyopaque,
    ) void {
        const T = @TypeOf(key);
        const info = @typeInfo(T);
        const Key = if (info != .Pointer) T else info.Pointer.child;
        const key_arg = if (@hasDecl(Key, "key"))
            key.key()
        else
            key;

        c.CFAttributedStringSetAttribute(
            @ptrCast(c.CFMutableAttributedStringRef, self),
            range.cval(),
            @ptrCast(c.CFStringRef, key_arg),
            value,
        );
    }
};

test "mutable attributed string" {
    //const testing = std.testing;

    const str = try MutableAttributedString.create(0);
    defer str.release();

    {
        const rep = try foundation.String.createWithBytes("hello", .utf8, false);
        defer rep.release();
        str.replaceString(foundation.Range.init(0, 0), rep);
    }

    str.setAttribute(foundation.Range.init(0, 0), text.FontAttribute.url, null);
    str.setAttribute(foundation.Range.init(0, 0), text.FontAttribute.name.key(), null);
}
