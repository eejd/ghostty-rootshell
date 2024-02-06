//! DFA-based non-allocating error-replacing UTF-8 decoder.
//!
//! This implementation is based largely on the excellent work of
//! Bjoern Hoehrmann, with slight modifications to support error-
//! replacement.
//!
//! For details on Bjoern's DFA-based UTF-8 decoder, see
//! http://bjoern.hoehrmann.de/utf-8/decoder/dfa (MIT licensed)

const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.utf8decoder);

//zig fmt: off
const char_classes = [_]u4{
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
   7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
   8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,  2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
  10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3, 11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,
};

const transitions = [_]u8 {
   0,12,24,36,60,96,84,12,12,12,48,72, 12,12,12,12,12,12,12,12,12,12,12,12,
  12, 0,12,12,12,12,12, 0,12, 0,12,12, 12,24,12,12,12,12,12,24,12,24,12,12,
  12,12,12,12,12,12,12,24,12,12,12,12, 12,24,12,12,12,12,12,12,12,24,12,12,
  12,12,12,12,12,12,12,36,12,36,12,12, 12,36,12,12,12,12,12,36,12,36,12,12,
  12,36,12,12,12,12,12,12,12,12,12,12,
};
//zig fmt: on

// This is where we accumulate our current codepoint.
var accumulator: u21 = 0;
// The internal state of the DFA.
const ACCEPT_STATE = 0;
const REJECT_STATE = 12;
var state: u8 = ACCEPT_STATE;

/// Takes the next byte in the utf-8 sequence and emits a tuple of
/// - The codepoint that was generated, if there is one.
/// - A boolean that indicates whether the provided byte was consumed.
///
/// The only case where the byte is not consumed is if an ill-formed
/// sequence is reached, in which case a replacement character will be
/// emitted and the byte will not be consumed.
///
/// If the byte is not consumed, the caller is responsible for calling
/// again with the same byte before continuing.
pub inline fn next(byte: u8) struct { ?u21, bool } {
    const char_class = char_classes[byte];

    const initial_state = state;

    if (state != ACCEPT_STATE) {
        accumulator <<= 6;
        accumulator |= (byte & 0x3F);
    } else {
        accumulator = (@as(u21, 0xFF) >> char_class) & (byte);
    }

    state = transitions[state + char_class];

    if (state == ACCEPT_STATE) {
        defer { accumulator = 0; }
        // Emit the fully decoded codepoint.
        return .{ accumulator, true };
    } else if (state == REJECT_STATE) {
        accumulator = 0;
        state = ACCEPT_STATE;
        // Emit a replacement character. If we rejected the first byte
        // in a sequence, then it was consumed, otherwise it was not.
        return .{ 0xFFFD, initial_state == ACCEPT_STATE };
    } else {
        // Emit nothing, we're in the middle of a sequence.
        return .{ null, true };
    }
}

test "ASCII" {
    var out = std.mem.zeroes([13]u8);
    for ("Hello, World!", 0..) |byte, i| {
        const res = next(byte);
        try testing.expect(res[1]);
        if (res[0]) |codepoint| {
            out[i] = @intCast(codepoint);
        }
    }
    try testing.expect(std.mem.eql(u8, &out, "Hello, World!"));
}

test "Well formed utf-8" {
    var out = std.mem.zeroes([4]u21);
    var i: usize = 0;
    // 4 bytes, 3 bytes, 2 bytes, 1 byte
    for ("😄✤ÁA") |byte| {
        var consumed = false;
        while (!consumed) {
            const res = next(byte);
            consumed = res[1];
            // There are no errors in this sequence, so
            // every byte should be consumed first try.
            try testing.expect(consumed == true);
            if (res[0]) |codepoint| {
                out[i] = codepoint;
                i += 1;
            }
        }
    }
    try testing.expect(std.mem.eql(u21, &out, &[_]u21{ 0x1F604, 0x2724, 0xC1, 0x41 }));
}

test "Partially invalid utf-8" {
    var out = std.mem.zeroes([5]u21);
    var i: usize = 0;
    // Illegally terminated sequence, valid sequence, illegal surrogate pair.
    for ("\xF0\x9F😄\xED\xA0\x80") |byte| {
        var consumed = false;
        while (!consumed) {
            const res = next(byte);
            consumed = res[1];
            if (res[0]) |codepoint| {
                out[i] = codepoint;
                i += 1;
            }
        }
    }
    try testing.expect(std.mem.eql(u21, &out, &[_]u21{ 0xFFFD, 0x1F604, 0xFFFD, 0xFFFD, 0xFFFD }));
}
