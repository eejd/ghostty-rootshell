const std = @import("std");

// vt.cpp
extern "c" fn ghostty_simd_codepoint_width(u32) i8;

pub fn codepointWidth(cp: u32) i8 {
    //return @import("ziglyph").display_width.codePointWidth(@intCast(cp), .half);
    return ghostty_simd_codepoint_width(cp);
}

test "codepointWidth basic" {
    const testing = std.testing;
    try testing.expectEqual(@as(i8, 1), codepointWidth('a'));
    try testing.expectEqual(@as(i8, 1), codepointWidth(0x100)); // Ā
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x3400)); // 㐀
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x2E3A)); // ⸺
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x1F1E6)); // 🇦
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x4E00)); // 一
    try testing.expectEqual(@as(i8, 2), codepointWidth(0xF900)); // 豈
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x20000)); // 𠀀
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x30000)); // 𠀀
    // try testing.expectEqual(@as(i8, 1), @import("ziglyph").display_width.codePointWidth(0x100, .half));
}

pub export fn ghostty_ziglyph_codepoint_width(cp: u32) callconv(.C) i8 {
    return @import("ziglyph").display_width.codePointWidth(@intCast(cp), .half);
}

test "codepointWidth matches ziglyph" {
    const testing = std.testing;
    const ziglyph = @import("ziglyph");

    // try testing.expect(ziglyph.general_category.isNonspacingMark(0x16fe4));
    // if (true) return;

    const min = 0xFF + 1; // start outside ascii
    for (min..std.math.maxInt(u21)) |cp| {
        const simd = codepointWidth(@intCast(cp));
        const zg = ziglyph.display_width.codePointWidth(@intCast(cp), .half);
        if (simd != zg) mismatch: {
            if (cp == 0x2E3B) {
                try testing.expectEqual(@as(i8, 2), simd);
                break :mismatch;
            }

            std.log.warn("mismatch cp=U+{x} simd={} zg={}", .{ cp, simd, zg });
            try testing.expect(false);
        }
    }
}
