/// KeyEncoder is responsible for processing keyboard input and generating
/// the proper VT sequence for any events.
///
/// A new KeyEncoder should be created for each individual key press.
/// These encoders are not meant to be reused.
const KeyEncoder = @This();

const std = @import("std");
const testing = std.testing;

const key = @import("key.zig");

key: key.Key,
binding_mods: key.Mods,

/// Initialize
fn init(event: key.Event) KeyEncoder {
    const effective_mods = event.effectiveMods();
    const binding_mods = effective_mods.binding();

    return .{
        .key = event.key,
        .binding_mods = binding_mods,
    };
}

/// Returns the C0 byte for the key event if it should be used.
/// This converts a key event into the expected terminal behavior
/// such as Ctrl+C turning into 0x03, amongst many other translations.
///
/// This will return null if the key event should not be converted
/// into a C0 byte. There are many cases for this and you should read
/// the source code to understand them.
fn ctrlSeq(self: *const KeyEncoder) ?u8 {
    // Remove alt from our modifiers because it does not impact whether
    // we are generating a ctrl sequence.
    const unalt_mods = unalt_mods: {
        var unalt_mods = self.binding_mods;
        unalt_mods.alt = false;
        break :unalt_mods unalt_mods;
    };

    // If we have any other modifier key set, then we do not generate
    // a C0 sequence.
    const ctrl_only = comptime (key.Mods{ .ctrl = true }).int();
    if (unalt_mods.int() != ctrl_only) return null;

    // The normal approach to get this value is to make the ascii byte
    // with 0x1F. However, not all apprt key translation will properly
    // generate the correct value so we just hardcode this based on
    // logical key.
    return switch (self.key) {
        .space => 0,
        .slash => 0x1F,
        .zero => 0x30,
        .one => 0x31,
        .two => 0x00,
        .three => 0x1B,
        .four => 0x1C,
        .five => 0x1D,
        .six => 0x1E,
        .seven => 0x1F,
        .eight => 0x7F,
        .nine => 0x39,
        .backslash => 0x1C,
        .left_bracket => 0x1B,
        .right_bracket => 0x1D,
        .a => 0x01,
        .b => 0x02,
        .c => 0x03,
        .d => 0x04,
        .e => 0x05,
        .f => 0x06,
        .g => 0x07,
        .h => 0x08,
        .i => 0x09,
        .j => 0x0A,
        .k => 0x0B,
        .l => 0x0C,
        .m => 0x0D,
        .n => 0x0E,
        .o => 0x0F,
        .p => 0x10,
        .q => 0x11,
        .r => 0x12,
        .s => 0x13,
        .t => 0x14,
        .u => 0x15,
        .v => 0x16,
        .w => 0x17,
        .x => 0x18,
        .y => 0x19,
        .z => 0x1A,
        else => null,
    };
}

test "ctrlseq: normal ctrl c" {
    const enc = init(.{ .key = .c, .mods = .{ .ctrl = true } });
    const seq = enc.ctrlSeq();
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: alt should be allowed" {
    const enc = init(.{ .key = .c, .mods = .{ .alt = true, .ctrl = true } });
    const seq = enc.ctrlSeq();
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: no ctrl does nothing" {
    const enc = init(.{ .key = .c, .mods = .{} });
    try testing.expect(enc.ctrlSeq() == null);
}

test "ctrlseq: shift does not generate ctrl seq" {
    {
        const enc = init(.{
            .key = .c,
            .mods = .{ .shift = true },
        });
        try testing.expect(enc.ctrlSeq() == null);
    }

    {
        const enc = init(.{
            .key = .c,
            .mods = .{ .shift = true, .ctrl = true },
        });
        try testing.expect(enc.ctrlSeq() == null);
    }
}
