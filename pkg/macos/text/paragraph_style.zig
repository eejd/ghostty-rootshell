const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

// https://developer.apple.com/documentation/coretext/ctparagraphstyle?language=objc
pub const ParagraphStyle = opaque {
    pub fn create(
        settings: []const ParagraphStyleSetting,
    ) Allocator.Error!*ParagraphStyle {
        return @ptrCast(@constCast(c.CTParagraphStyleCreate(
            @ptrCast(settings.ptr),
            settings.len,
        )));
    }

    pub fn release(self: *ParagraphStyle) void {
        foundation.CFRelease(self);
    }
};

/// https://developer.apple.com/documentation/coretext/ctparagraphstylesetting?language=objc
pub const ParagraphStyleSetting = extern struct {
    spec: ParagraphStyleSpecifier,
    value_size: usize,
    value: *const anyopaque,
};

/// https://developer.apple.com/documentation/coretext/ctparagraphstylespecifier?language=objc
pub const ParagraphStyleSpecifier = enum(c_uint) {
    base_writing_direction = 13,
};

pub const WritingDirection = enum(i8) {
    natural = -1,
    left_to_right = 0,
    right_to_left = 1,
};

test ParagraphStyle {
    const p = try ParagraphStyle.create(&.{});
    defer p.release();
}
