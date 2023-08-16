//! This file has information related to Paul Evans's "fixterms"
//! encoding, also sometimes referred to as "CSI u" encoding.
//!
//! https://www.leonerd.org.uk/hacks/fixterms/

const std = @import("std");

const input = @import("../input.zig");

pub const Mods = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,

    /// Convert an input mods value into the CSI u mods value.
    pub fn fromInput(mods: input.Mods) Mods {
        return .{
            .shift = mods.shift,
            .alt = mods.alt,
            .ctrl = mods.ctrl,
        };
    }

    /// Returns the raw int value of this packed struct.
    pub fn int(self: Mods) u3 {
        return @bitCast(self);
    }

    /// Returns the integer value sent as part of the CSI u sequence.
    /// This adds 1 to the bitmask value as described in the spec.
    pub fn seqInt(self: Mods) u4 {
        const raw: u4 = @intCast(self.int());
        return raw + 1;
    }
};

test "modifer sequence values" {
    // This is all sort of trivially seen by looking at the code but
    // we want to make sure we never regress this.
    const testing = std.testing;
    var mods: Mods = .{};
    try testing.expectEqual(@as(u4, 1), mods.seqInt());

    mods = .{ .shift = true };
    try testing.expectEqual(@as(u4, 2), mods.seqInt());

    mods = .{ .alt = true };
    try testing.expectEqual(@as(u4, 3), mods.seqInt());

    mods = .{ .ctrl = true };
    try testing.expectEqual(@as(u4, 5), mods.seqInt());

    mods = .{ .alt = true, .shift = true };
    try testing.expectEqual(@as(u4, 4), mods.seqInt());

    mods = .{ .ctrl = true, .shift = true };
    try testing.expectEqual(@as(u4, 6), mods.seqInt());

    mods = .{ .alt = true, .ctrl = true };
    try testing.expectEqual(@as(u4, 7), mods.seqInt());

    mods = .{ .alt = true, .ctrl = true, .shift = true };
    try testing.expectEqual(@as(u4, 8), mods.seqInt());
}
