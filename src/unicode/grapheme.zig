const std = @import("std");
const props = @import("props.zig");
const table = props.table;

/// Grapheme break
pub fn graphemeBreak(cp1: u21, cp2: u21, state: *u3) bool {
    const gbc1 = table.get(cp1).grapheme_boundary_class;
    const gbc2 = table.get(cp2).grapheme_boundary_class;
    // std.log.warn("gbc1={} gbc2={}, new1={} new2={}", .{
    //     gbc1,
    //     gbc2,
    //     props.GraphemeBoundaryClass.init(cp1),
    //     props.GraphemeBoundaryClass.init(cp2),
    // });

    // GB11: Emoji Extend* ZWJ x Emoji
    if (!hasXpic(state) and gbc1 == .extended_pictographic) setXpic(state);

    // These two properties are ignored because they're not relevant to
    // Ghostty -- they're filtered out before checking grapheme boundaries.
    // GB3: CR x LF
    // GB4: Control

    // GB6: Hangul L x (L|V|LV|VT)
    if (gbc1 == .L) {
        if (gbc2 == .L or
            gbc2 == .V or
            gbc2 == .LV or
            gbc2 == .LVT) return false;
    }

    // GB7: Hangul (LV | V) x (V | T)
    if (gbc1 == .LV or gbc1 == .V) {
        if (gbc2 == .V or
            gbc2 == .T) return false;
    }

    // GB8: Hangul (LVT | T) x T
    if (gbc1 == .LVT or gbc1 == .T) {
        if (gbc2 == .T) return false;
    }

    // GB9b: x (Extend | ZWJ)
    if (gbc2 == .extend or gbc2 == .zwj) return false;

    // GB9a: x Spacing
    if (gbc2 == .spacing_mark) return false;

    // GB9b: Prepend x
    if (gbc1 == .prepend) return false;

    // GB12, GB13: RI x RI
    if (gbc1 == .regional_indicator and gbc2 == .regional_indicator) {
        if (hasRegional(state)) {
            unsetRegional(state);
            return true;
        } else {
            setRegional(state);
            return false;
        }
    }

    // GB11: Emoji Extend* ZWJ x Emoji
    if (hasXpic(state) and
        gbc1 == .zwj and
        gbc2 == .extended_pictographic)
    {
        unsetXpic(state);
        return false;
    }

    return true;
}

const emoji = @import("ziglyph").emoji;
const gbp = @import("ziglyph").grapheme_break;

fn isBreaker(cp: u21) bool {
    return cp == '\x0d' or cp == '\x0a' or gbp.isControl(cp);
}

pub fn zg_graphemeBreak(
    cp1: u21,
    cp2: u21,
    state: *u3,
) bool {

    // GB11: Emoji Extend* ZWJ x Emoji
    if (!hasXpic(state) and emoji.isExtendedPictographic(cp1)) setXpic(state);

    // GB3: CR x LF
    if (cp1 == '\r' and cp2 == '\n') {
        std.log.warn("GB3", .{});
        return false;
    }

    // GB4: Control
    if (isBreaker(cp1)) {
        std.log.warn("GB4", .{});
        return true;
    }

    // GB6: Hangul L x (L|V|LV|VT)
    if (gbp.isL(cp1)) {
        if (gbp.isL(cp2) or
            gbp.isV(cp2) or
            gbp.isLv(cp2) or
            gbp.isLvt(cp2))
        {
            std.log.warn("GB6", .{});
            return false;
        }
    }

    // GB7: Hangul (LV | V) x (V | T)
    if (gbp.isLv(cp1) or gbp.isV(cp1)) {
        if (gbp.isV(cp2) or
            gbp.isT(cp2))
        {
            std.log.warn("GB7", .{});
            return false;
        }
    }

    // GB8: Hangul (LVT | T) x T
    if (gbp.isLvt(cp1) or gbp.isT(cp1)) {
        if (gbp.isT(cp2)) {
            std.log.warn("GB8", .{});
            return false;
        }
    }

    // GB9b: x (Extend | ZWJ)
    if (gbp.isExtend(cp2) or gbp.isZwj(cp2)) {
        std.log.warn("GB9b", .{});
        return false;
    }

    // GB9a: x Spacing
    if (gbp.isSpacingmark(cp2)) {
        std.log.warn("GB9a", .{});
        return false;
    }

    // GB9b: Prepend x
    if (gbp.isPrepend(cp1) and !isBreaker(cp2)) {
        std.log.warn("GB9b cp1={x} prepend={}", .{ cp1, gbp.isPrepend(cp1) });
        return false;
    }

    // GB12, GB13: RI x RI
    if (gbp.isRegionalIndicator(cp1) and gbp.isRegionalIndicator(cp2)) {
        if (hasRegional(state)) {
            unsetRegional(state);
            std.log.warn("GB12", .{});
            return true;
        } else {
            std.log.warn("GB13", .{});
            setRegional(state);
            return false;
        }
    }

    // GB11: Emoji Extend* ZWJ x Emoji
    if (hasXpic(state) and
        gbp.isZwj(cp1) and
        emoji.isExtendedPictographic(cp2))
    {
        std.log.warn("GB11", .{});
        unsetXpic(state);
        return false;
    }

    return true;
}

fn hasXpic(state: *const u3) bool {
    return state.* & 1 == 1;
}

fn setXpic(state: *u3) void {
    state.* |= 1;
}

fn unsetXpic(state: *u3) void {
    state.* ^= 1;
}

fn hasRegional(state: *const u3) bool {
    return state.* & 2 == 2;
}

fn setRegional(state: *u3) void {
    state.* |= 2;
}

fn unsetRegional(state: *u3) void {
    state.* ^= 2;
}

/// If you build this file as a binary, we will verify the grapheme break
/// implementation. This iterates over billions of codepoints so it is
/// SLOW. It's not meant to be run in CI, but it's useful for debugging.
pub fn main() !void {
    const ziglyph = @import("ziglyph");

    var state: u3 = 0;
    var zg_state: u3 = 0;
    for (0..std.math.maxInt(u21) + 1) |cp1| {
        if (cp1 % 1000 == 0) std.log.warn("progress cp1={}", .{cp1});

        if (cp1 == '\r' or cp1 == '\n' or
            ziglyph.grapheme_break.isControl(@intCast(cp1))) continue;

        for (0..std.math.maxInt(u21) + 1) |cp2| {
            if (cp2 == '\r' or cp2 == '\n' or
                ziglyph.grapheme_break.isControl(@intCast(cp2))) continue;

            const gb = graphemeBreak(@intCast(cp1), @intCast(cp2), &state);
            const zg_gb = ziglyph.graphemeBreak(@intCast(cp1), @intCast(cp2), &zg_state);
            if (gb != zg_gb) {
                std.log.warn("cp1={x} cp2={x} gb={} state={} zg_gb={} zg_state={}", .{
                    cp1,
                    cp2,
                    gb,
                    state,
                    zg_gb,
                    zg_state,
                });
            }
        }
    }
}

pub const std_options = struct {
    pub const log_level: std.log.Level = .info;
};

// test "matches ziglyph specific" {
//     const testing = std.testing;
//
//     var state: u3 = 0;
//     var zg_state: u3 = 0;
//
//     const cp1 = 0x20;
//     const cp2 = 0x300;
//
//     const gb = graphemeBreak(@intCast(cp1), @intCast(cp2), &state);
//     const zg_gb = zg_graphemeBreak(@intCast(cp1), @intCast(cp2), &zg_state);
//     if (gb != zg_gb) {
//         std.log.warn("cp1={x} cp2={x} gb={} state={} zg_gb={} zg_state={}", .{
//             cp1,
//             cp2,
//             gb,
//             state,
//             zg_gb,
//             zg_state,
//         });
//         try testing.expect(false);
//     }
// }
