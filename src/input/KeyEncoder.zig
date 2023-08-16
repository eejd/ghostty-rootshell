/// KeyEncoder is responsible for processing keyboard input and generating
/// the proper VT sequence for any events.
///
/// A new KeyEncoder should be created for each individual key press.
/// These encoders are not meant to be reused.
const KeyEncoder = @This();

const std = @import("std");
const testing = std.testing;

const key = @import("key.zig");
const function_keys = @import("function_keys.zig");

event: key.Event,

/// The state of various modes of a terminal that impact encoding.
cursor_key_application: bool = false,
keypad_key_application: bool = false,
modify_other_keys_state_2: bool = false,

/// Perform legacy encoding of the key event. "Legacy" in this case
/// is referring to the behavior of traditional terminals, plus
/// xterm's `modifyOtherKeys`, plus Paul Evans's "fixterms" spec.
/// These together combine the legacy protocol because they're all
/// meant to be extensions that do not change any existing behavior
/// and therefore safe to combine.
fn legacy(
    self: *const KeyEncoder,
    buf: []u8,
) ![]const u8 {
    const effective_mods = self.event.effectiveMods();
    const binding_mods = effective_mods.binding();

    // Legacy encoding only does press/repeat
    if (self.event.action != .press and
        self.event.action != .repeat) return "";

    // If we match a PC style function key then that is our result.
    if (pcStyleFunctionKey(
        self.event.key,
        binding_mods,
        self.cursor_key_application,
        self.keypad_key_application,
        self.modify_other_keys_state_2,
    )) |sequence| return sequence;

    // If we match a control sequence, we output that directly.
    if (ctrlSeq(self.event.key, binding_mods)) |char| {
        // C0 sequences support alt-as-esc prefixing.
        if (binding_mods.alt) {
            if (buf.len < 2) return error.OutOfMemory;
            buf[0] = 0x1B;
            buf[1] = char;
            return buf[0..2];
        }

        if (buf.len < 1) return error.OutOfMemory;
        buf[0] = char;
        return buf[0..1];
    }

    return "";
}

/// Determines whether the key should be encoded in the xterm
/// "PC-style Function Key" syntax (roughly). This is a hardcoded
/// table of keys and modifiers that result in a specific sequence.
fn pcStyleFunctionKey(
    keyval: key.Key,
    mods: key.Mods,
    cursor_key_application: bool,
    keypad_key_application: bool,
    modify_other_keys: bool, // True if state 2
) ?[]const u8 {
    const mods_int = mods.int();
    for (function_keys.keys.get(keyval)) |entry| {
        switch (entry.cursor) {
            .any => {},
            .normal => if (cursor_key_application) continue,
            .application => if (!cursor_key_application) continue,
        }

        switch (entry.keypad) {
            .any => {},
            .normal => if (keypad_key_application) continue,
            .application => if (!keypad_key_application) continue,
        }

        switch (entry.modify_other_keys) {
            .any => {},
            .set => if (modify_other_keys) continue,
            .set_other => if (!modify_other_keys) continue,
        }

        const entry_mods_int = entry.mods.int();
        if (entry_mods_int == 0) {
            if (mods_int != 0 and !entry.mods_empty_is_any) continue;
            // mods are either empty, or empty means any so we allow it.
        } else if (entry_mods_int != mods_int) {
            // any set mods require an exact match
            continue;
        }

        return entry.sequence;
    }

    return null;
}

/// Returns the C0 byte for the key event if it should be used.
/// This converts a key event into the expected terminal behavior
/// such as Ctrl+C turning into 0x03, amongst many other translations.
///
/// This will return null if the key event should not be converted
/// into a C0 byte. There are many cases for this and you should read
/// the source code to understand them.
fn ctrlSeq(keyval: key.Key, mods: key.Mods) ?u8 {
    // Remove alt from our modifiers because it does not impact whether
    // we are generating a ctrl sequence.
    const unalt_mods = unalt_mods: {
        var unalt_mods = mods;
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
    return switch (keyval) {
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

test "legacy: ctrl+alt+c" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .c,
            .mods = .{ .ctrl = true, .alt = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1b\x03", actual);
}

test "legacy: ctrl+c" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .c,
            .mods = .{ .ctrl = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x03", actual);
}

test "legacy: ctrl+space" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .space,
            .mods = .{ .ctrl = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x00", actual);
}

test "legacy: ctrl+shift+backspace" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .backspace,
            .mods = .{ .ctrl = true, .shift = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x08", actual);
}

test "ctrlseq: normal ctrl c" {
    const seq = ctrlSeq(.c, .{ .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: alt should be allowed" {
    const seq = ctrlSeq(.c, .{ .alt = true, .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: no ctrl does nothing" {
    try testing.expect(ctrlSeq(.c, .{}) == null);
}

test "ctrlseq: shift does not generate ctrl seq" {
    try testing.expect(ctrlSeq(.c, .{ .shift = true }) == null);
    try testing.expect(ctrlSeq(.c, .{ .shift = true, .ctrl = true }) == null);
}
