const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const Framesetter = opaque {
    pub fn createWithAttributedString(str: *foundation.AttributedString) Allocator.Error!*Framesetter {
        return @intToPtr(
            ?*Framesetter,
            @ptrToInt(c.CTFramesetterCreateWithAttributedString(
                @ptrCast(c.CFAttributedStringRef, str),
            )),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Framesetter) void {
        foundation.CFRelease(self);
    }
};

test {
    const str = try foundation.MutableAttributedString.create(0);
    defer str.release();
    {
        const rep = try foundation.String.createWithBytes("hello", .utf8, false);
        defer rep.release();
        str.replaceString(foundation.Range.init(0, 0), rep);
    }

    const fs = try Framesetter.createWithAttributedString(@ptrCast(*foundation.AttributedString, str));
    defer fs.release();
}
