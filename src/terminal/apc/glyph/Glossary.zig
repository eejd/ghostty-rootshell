/// Glossary is the per-terminal storage for Glyph Protocol
/// codepoints. We use the word Glossary to match up with the spec which
/// also uses this word.
const Glossary = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../../datastruct/circ_buf.zig").CircBuf;
const face = @import("../../../font/face.zig");
const Glyf = @import("../../../font/opentype/glyf.zig").Glyf;
const glyf_rasterize = @import("../../../font/glyf_rasterize.zig");

const request = @import("request.zig");
const RegisterReq = request.Request.Register;

/// The set of entries in the glossary keyed by the codepoint.
///
/// The array hash map preserves insertion order and has O(N)
/// orderedRemove, so we use it as a FIFO too for eviction when
/// the glossary is full. Since the specification limits the protocol
/// to 1024 maximum entries, ordered removal should never be that
/// expensive.
///
/// I'm also operating under the assumption that full glossaries
/// for a session will be rare, so the eviction cost shouldn't
/// happen regularly.
entries: std.AutoArrayHashMap(u21, Entry),

/// A single glyph registration entry.
pub const Entry = struct {
    /// Stored glyph payload variants.
    pub const Glyph = union(enum) {
        glyf: Glyf.Outline,
    };

    /// The glyph itself. The tagged union only has glyf right now but
    /// will eventually expand to support COLR and maybe other formats.
    /// These are stored as raw outlines; rasterization is delayed to
    /// renderers. The outlines have been validated.
    glyph: Glyph,

    /// Authored metrics for the glyph's design coordinate space.
    design: glyf_rasterize.DesignMetrics,

    /// Unicode cell width requested by the registration.
    width: request.Width,

    /// Normalized scale, alignment, and padding behavior for rasterization.
    constraint: face.RenderOptions.Constraint,

    /// Errors that can occur while constructing a glossary entry from a
    /// register request.
    pub const InitError = RegisterReq.DecodeError || error{
        /// The register request is missing a required option or has an invalid
        /// explicitly-provided option value.
        InvalidOptions,

        /// `cp` is not in any PUA range.
        OutOfNamespace,

        /// The requested payload format is not supported by this glossary.
        UnsupportedFormat,
    };

    /// Initialize a glossary entry from a register request.
    ///
    /// This validates the request fields needed to construct the entry,
    /// decodes the base64 glyph payload, and stores the decoded outline. The
    /// returned entry owns decoded glyph memory and must be released with
    /// `deinit`.
    pub fn init(alloc: Allocator, register: RegisterReq) InitError!Entry {
        // Validate codepoint
        const cp = register.get(.cp) orelse return error.InvalidOptions;
        if (!isPrivateUse(cp)) return error.OutOfNamespace;

        // Validate format
        const fmt = register.get(.fmt) orelse return error.InvalidOptions;
        const design: glyf_rasterize.DesignMetrics = .{
            .units_per_em = register.get(.upm) orelse return error.InvalidOptions,
            .advance_width = register.get(.aw) orelse return error.InvalidOptions,
            .line_height = register.get(.lh) orelse return error.InvalidOptions,
        };
        if (design.units_per_em == 0 or
            design.advance_width == 0 or
            design.line_height == 0) return error.InvalidOptions;
        const width = register.get(.width) orelse return error.InvalidOptions;

        // Get our constraints
        const constraint = try constraintFromRegister(register);

        // Decode the payload into some usable glyph format for
        // future rasterization.
        const glyph: Glyph = switch (fmt) {
            .glyf => .{ .glyf = try register.decodeGlyfPayload(alloc) },
            .colrv0, .colrv1 => return error.UnsupportedFormat,
        };

        // No more errors, since we never do glyph cleanup above.
        errdefer comptime unreachable;

        return .{
            .glyph = glyph,
            .design = design,
            .width = width,
            .constraint = constraint,
        };
    }

    /// Release memory owned by this entry.
    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.glyph) {
            .glyf => |*outline| outline.deinit(alloc),
        }
        self.* = undefined;
    }

    /// Return the renderer constraint for a register request.
    ///
    /// Glyph Protocol §8.5 defines sizing, alignment, and padding in terms of
    /// the authored extent and render span. Ghostty's existing constraint type
    /// is the closest renderer-native representation for these controls, but
    /// it does not have exact equivalents for every protocol size mode, so this
    /// function is the single normalization point for those policy choices.
    fn constraintFromRegister(
        register: RegisterReq,
    ) error{InvalidOptions}!face.RenderOptions.Constraint {
        // Register.get applies the Glyph Protocol §6.1 defaults when options
        // are omitted: size=height, align=center,center, and pad=0,0,0,0.
        const size = register.get(.size) orelse return error.InvalidOptions;
        const alignment = register.get(.@"align") orelse return error.InvalidOptions;
        const pad = register.get(.pad) orelse return error.InvalidOptions;

        return .{
            .size = switch (size) {
                // The rasterizer's base transform already maps the design em
                // to the cell height. That is the closest existing behavior to
                // the protocol's default height-driven mode.
                .height => .none,
                // There is no width-driven, aspect-preserving constraint mode
                // today. Leave the base transform intact rather than forcing a
                // fit/contain policy that would unexpectedly prevent overflow.
                .advance => .none,
                // Constraint.cover currently scales preserving aspect ratio to
                // the available bounds, which is the best existing match for
                // the protocol's contain mode.
                .contain => .cover,
                // There is no true protocol-cover equivalent that chooses the
                // larger axis scale, so use the nearest named renderer policy.
                .cover => .cover,
                .stretch => .stretch,
            },
            .align_horizontal = switch (alignment.horizontal) {
                .start => .start,
                .center => .center,
                .end => .end,
            },
            .align_vertical = switch (alignment.vertical) {
                .start => .start,
                .center => .center,
                .end => .end,
                // The current constraint API has no baseline alignment mode.
                // Start is the closest stable default because the glyf
                // rasterizer's coordinate model already treats y=0 as the
                // baseline/bottom before constraints are applied.
                .baseline => .start,
            },
            .pad_top = pad.top,
            .pad_right = pad.right,
            .pad_bottom = pad.bottom,
            .pad_left = pad.left,
        };
    }

    /// Return true if `cp` is in one of the Unicode Private Use Areas.
    fn isPrivateUse(cp: u21) bool {
        return (cp >= 0xE000 and cp <= 0xF8FF) or
            (cp >= 0xF0000 and cp <= 0xFFFFD) or
            (cp >= 0x100000 and cp <= 0x10FFFD);
    }
};

fn testParseRegister(alloc: Allocator, data: []const u8) !RegisterReq {
    const raw = try alloc.dupe(u8, data);
    errdefer alloc.free(raw);

    const req = try request.Request.parse(alloc, raw);
    switch (req) {
        .register => |register| return register,
        else => unreachable,
    }
}

test "Entry init decodes glyf payload and applies register fields" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const register = try testParseRegister(
        alloc,
        "r;cp=e000;upm=2048;aw=1024;lh=1536;width=2;size=stretch;align=end,start;pad=0.1,0.2,0.3,0.4;AAAAAAAAAAAAAA==",
    );
    defer alloc.free(register.raw);

    var entry = try Entry.init(alloc, register);
    defer entry.deinit(alloc);

    try testing.expectEqual(@as(u32, 2048), entry.design.units_per_em);
    try testing.expectEqual(@as(u32, 1024), entry.design.advance_width);
    try testing.expectEqual(@as(u32, 1536), entry.design.line_height);
    try testing.expectEqual(request.Width.wide, entry.width);
    try testing.expectEqual(face.RenderOptions.Constraint.Size.stretch, entry.constraint.size);
    try testing.expectEqual(face.RenderOptions.Constraint.Align.end, entry.constraint.align_horizontal);
    try testing.expectEqual(face.RenderOptions.Constraint.Align.start, entry.constraint.align_vertical);
    try testing.expectEqual(@as(f64, 0.1), entry.constraint.pad_top);
    try testing.expectEqual(@as(f64, 0.2), entry.constraint.pad_right);
    try testing.expectEqual(@as(f64, 0.3), entry.constraint.pad_bottom);
    try testing.expectEqual(@as(f64, 0.4), entry.constraint.pad_left);

    try testing.expectEqual(@as(usize, 0), entry.glyph.glyf.points.len);
    try testing.expectEqual(@as(usize, 0), entry.glyph.glyf.contours.len);
}

test "Entry init rejects invalid register payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const register = try testParseRegister(alloc, "r;cp=e000;%%%not-base64%%%");
    defer alloc.free(register.raw);

    try testing.expectError(error.MalformedPayload, Entry.init(alloc, register));
}
