const props = @This();
const std = @import("std");
const ziglyph = @import("ziglyph");
const lut = @import("lut.zig");

/// The lookup tables for Ghostty.
pub const table = table: {
    // This is only available after running main() below as part of the Ghostty
    // build.zig, but due to Zig's lazy analysis we can still reference it here.
    const generated = @import("unicode_tables").Tables(Properties);
    const Tables = lut.Tables(Properties);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};

/// Property set per codepoint that Ghostty cares about.
///
/// Adding to this lets you find new properties but also potentially makes
/// our lookup tables less efficient. Any changes to this should run the
/// benchmarks in src/bench to verify that we haven't regressed.
pub const Properties = struct {
    /// Codepoint width. We clamp to [0, 2] since Ghostty handles control
    /// characters and we max out at 2 for wide characters (i.e. 3-em dash
    /// becomes a 2-em dash).
    width: u2 = 0,

    // Needed for lut.Generator
    pub fn eql(a: Properties, b: Properties) bool {
        return a.width == b.width;
    }

    // Needed for lut.Generator
    pub fn format(
        self: Properties,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;
        try std.fmt.format(writer, ".{{ .width= {}, }}", .{
            self.width,
        });
    }
};

pub fn get(cp: u21) Properties {
    const zg_width = ziglyph.display_width.codePointWidth(cp, .half);

    return .{
        .width = @intCast(@min(2, @max(0, zg_width))),
    };
}

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main() !void {
    const alloc = std.heap.c_allocator;

    const gen: lut.Generator(
        Properties,
        struct {
            pub fn get(ctx: @This(), cp: u21) !Properties {
                _ = ctx;
                return props.get(cp);
            }

            pub fn eql(ctx: @This(), a: Properties, b: Properties) bool {
                _ = ctx;
                return a.eql(b);
            }
        },
    ) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    defer alloc.free(t.stage3);
    try t.writeZig(std.io.getStdOut().writer());

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={} stage3={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    //     t.stage3.len,
    // });
}

// This is not very fast in debug modes, so its commented by default.
// IMPORTANT: UNCOMMENT THIS WHENEVER MAKING CODEPOINTWIDTH CHANGES.
// test "tables match ziglyph" {
//     const testing = std.testing;
//
//     const min = 0xFF + 1; // start outside ascii
//     for (min..std.math.maxInt(u21)) |cp| {
//         const t = table.get(@intCast(cp));
//         const zg = @min(2, @max(0, ziglyph.display_width.codePointWidth(@intCast(cp), .half)));
//         if (t.width != zg) {
//             std.log.warn("mismatch cp=U+{x} t={} zg={}", .{ cp, t, zg });
//             try testing.expect(false);
//         }
//     }
// }
