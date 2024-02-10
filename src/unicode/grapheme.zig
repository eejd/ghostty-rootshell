const std = @import("std");
const props = @import("props.zig");
const GraphemeBoundaryClass = props.GraphemeBoundaryClass;
const table = props.table;

// The algorithm in this file is based on the Ziglyph and utf8proc algorithm,
// only modified to use our own lookup tables.
//
// I'll note I also tried a fully precomputed table approach where all
// combinations of state and boundary classes were precomputed. It was
// marginally faster (about 2%) but the table is a few KB and I'm not
// sure it's worth it.

/// Determines if there is a grapheme break between two codepoints. This
/// must be called sequentially maintaining the state between calls.
///
/// This function does NOT work with control characters. Control characters,
/// line feeds, and carriage returns are expected to be filtered out before
/// calling this function. This is because this function is tuned for
/// Ghostty.
pub fn graphemeBreak(cp1: u21, cp2: u21, state: *u3) bool {
    const gbc1 = table.get(cp1).grapheme_boundary_class;
    const gbc2 = table.get(cp2).grapheme_boundary_class;
    return graphemeBreakClass(gbc1, gbc2, state);
}

fn graphemeBreakClass(
    gbc1: GraphemeBoundaryClass,
    gbc2: GraphemeBoundaryClass,
    state: *u3,
) bool {
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

const State = packed struct(u2) {
    extended_pictographic: bool = false,
    regional_indicator: bool = false,
};

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

    // Set the min and max to control the test range.
    const min = 0;
    const max = std.math.maxInt(u21) + 1;

    var state: u3 = 0;
    var zg_state: u3 = 0;
    for (min..max) |cp1| {
        if (cp1 % 1000 == 0) std.log.warn("progress cp1={}", .{cp1});

        if (cp1 == '\r' or cp1 == '\n' or
            ziglyph.grapheme_break.isControl(@intCast(cp1))) continue;

        for (min..max) |cp2| {
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
