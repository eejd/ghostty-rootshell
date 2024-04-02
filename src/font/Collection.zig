//! A font collection is a list of faces of different styles. The list is
//! ordered by priority (per style). All fonts in a collection share the same
//! size so they can be used interchangeably in cases a glyph is missing in one
//! and present in another.
const Collection = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("main.zig");
const DeferredFace = font.DeferredFace;
const Face = font.Face;
const Library = font.Library;
const Presentation = font.Presentation;
const Style = font.Style;

/// The available faces we have. This shouldn't be modified manually.
/// Instead, use the functions available on Collection.
faces: StyleArray,

/// Initialize an empty collection.
pub fn init(alloc: Allocator) !Collection {
    // Initialize our styles array, preallocating some space that is
    // likely to be used.
    var faces = StyleArray.initFill(.{});
    for (&faces.values) |*list| try list.ensureTotalCapacityPrecise(alloc, 2);
    return .{ .faces = faces };
}

pub fn deinit(self: *Collection, alloc: Allocator) void {
    var it = self.faces.iterator();
    while (it.next()) |entry| {
        for (entry.value.items) |*item| item.deinit();
        entry.value.deinit(alloc);
    }
}

pub const AddError = Allocator.Error || error{
    CollectionFull,
};

/// Add a face to the collection for the given style. This face will be added
/// next in priority if others exist already, i.e. it'll be the _last_ to be
/// searched for a glyph in that list.
///
/// The collection takes ownership of the face. The face will be deallocated
/// when the collection is deallocated.
///
/// If a loaded face is added to the collection, it should be the same
/// size as all the other faces in the collection. This function will not
/// verify or modify the size until the size of the entire collection is
/// changed.
pub fn add(
    self: *Collection,
    alloc: Allocator,
    style: Style,
    face: Entry,
) AddError!Index {
    const list = self.faces.getPtr(style);

    // We have some special indexes so we must never pass those.
    if (list.items.len >= Index.Special.start - 1)
        return error.CollectionFull;

    const idx = list.items.len;
    try list.append(alloc, face);
    return .{ .style = style, .idx = @intCast(idx) };
}

/// Packed array of all Style enum cases mapped to a growable list of faces.
///
/// We use this data structure because there aren't many styles and all
/// styles are typically loaded for a terminal session. The overhead per
/// style even if it is not used or barely used is minimal given the
/// small style count.
const StyleArray = std.EnumArray(Style, std.ArrayListUnmanaged(Entry));

/// A entry in a collection can be deferred or loaded. A deferred face
/// is not yet fully loaded and only represents the font descriptor
/// and usually uses less resources. A loaded face is fully parsed,
/// ready to rasterize, and usually uses more resources than a
/// deferred version.
///
/// A face can also be a "fallback" variant that is still either
/// deferred or loaded. Today, there is only one difference between
/// fallback and non-fallback (or "explicit") faces: the handling
/// of emoji presentation.
///
/// For explicit faces, when an explicit emoji presentation is
/// not requested, we will use any glyph for that codepoint found
/// even if the font presentation does not match the UCD
/// (Unicode Character Database) value. When an explicit presentation
/// is requested (via either VS15/V16), that is always honored.
/// The reason we do this is because we assume that if a user
/// explicitly chosen a font face (hence it is "explicit" and
/// not "fallback"), they want to use any glyphs possible within that
/// font face. Fallback fonts on the other hand are picked as a
/// last resort, so we should prefer exactness if possible.
pub const Entry = union(enum) {
    deferred: DeferredFace, // Not loaded
    loaded: Face, // Loaded, explicit use

    // The same as deferred/loaded but fallback font semantics (see large
    // comment above Entry).
    fallback_deferred: DeferredFace,
    fallback_loaded: Face,

    pub fn deinit(self: *Entry) void {
        switch (self.*) {
            inline .deferred,
            .loaded,
            .fallback_deferred,
            .fallback_loaded,
            => |*v| v.deinit(),
        }
    }

    /// True if this face satisfies the given codepoint and presentation.
    fn hasCodepoint(self: Entry, cp: u32, p_mode: PresentationMode) bool {
        return switch (self) {
            // Non-fallback fonts require explicit presentation matching but
            // otherwise don't care about presentation
            .deferred => |v| switch (p_mode) {
                .explicit => |p| v.hasCodepoint(cp, p),
                .default, .any => v.hasCodepoint(cp, null),
            },

            .loaded => |face| switch (p_mode) {
                .explicit => |p| face.presentation == p and face.glyphIndex(cp) != null,
                .default, .any => face.glyphIndex(cp) != null,
            },

            // Fallback fonts require exact presentation matching.
            .fallback_deferred => |v| switch (p_mode) {
                .explicit, .default => |p| v.hasCodepoint(cp, p),
                .any => v.hasCodepoint(cp, null),
            },

            .fallback_loaded => |face| switch (p_mode) {
                .explicit,
                .default,
                => |p| face.presentation == p and face.glyphIndex(cp) != null,
                .any => face.glyphIndex(cp) != null,
            },
        };
    }
};

/// The requested presentation for a codepoint.
pub const PresentationMode = union(enum) {
    /// The codepoint has an explicit presentation that is required,
    /// i.e. VS15/V16.
    explicit: Presentation,

    /// The codepoint has no explicit presentation and we should use
    /// the presentation from the UCd.
    default: Presentation,

    /// The codepoint can be any presentation.
    any: void,
};

/// This represents a specific font in the collection.
///
/// The backing size of this packed struct represents the total number
/// of possible usable fonts in a collection. And the number of bits
/// used for the index and not the style represents the total number
/// of possible usable fonts for a given style.
///
/// The goal is to keep the size of this struct as small as practical. We
/// accept the limitations that this imposes so long as they're reasonable.
/// At the time of writing this comment, this is a 16-bit struct with 13
/// bits used for the index, supporting up to 8192 fonts per style. This
/// seems more than reasonable. There are synthetic scenarios where this
/// could be a limitation but I can't think of any that are practical.
///
/// If you somehow need more fonts per style, you can increase the size of
/// the Backing type and everything should just work fine.
pub const Index = packed struct(Index.Backing) {
    const Backing = u16;
    const backing_bits = @typeInfo(Backing).Int.bits;

    /// The number of bits we use for the index.
    const idx_bits = backing_bits - @typeInfo(@typeInfo(Style).Enum.tag_type).Int.bits;
    pub const IndexInt = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = idx_bits } });

    /// The special-case fonts that we support.
    pub const Special = enum(IndexInt) {
        // We start all special fonts at this index so they can be detected.
        pub const start = std.math.maxInt(IndexInt);

        /// Sprite drawing, this is rendered JIT using 2D graphics APIs.
        sprite = start,
    };

    style: Style = .regular,
    idx: IndexInt = 0,

    /// Initialize a special font index.
    pub fn initSpecial(v: Special) Index {
        return .{ .style = .regular, .idx = @intFromEnum(v) };
    }

    /// Convert to int
    pub fn int(self: Index) Backing {
        return @bitCast(self);
    }

    /// Returns true if this is a "special" index which doesn't map to
    /// a real font face. We can still render it but there is no face for
    /// this font.
    pub fn special(self: Index) ?Special {
        if (self.idx < Special.start) return null;
        return @enumFromInt(self.idx);
    }

    test {
        // We never want to take up more than a byte since font indexes are
        // everywhere so if we increase the size of this we'll dramatically
        // increase our memory usage.
        try std.testing.expectEqual(@sizeOf(Backing), @sizeOf(Index));

        // Just so we're aware when this changes. The current maximum number
        // of fonts for a style is 13 bits or 8192 fonts.
        try std.testing.expectEqual(13, idx_bits);
    }
};

test init {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try init(alloc);
    defer c.deinit(alloc);
}

test "add full" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var lib = try Library.init();
    defer lib.deinit();

    var c = try init(alloc);
    defer c.deinit(alloc);

    for (0..Index.Special.start - 1) |_| {
        _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
            lib,
            testFont,
            .{ .size = .{ .points = 12 } },
        ) });
    }

    try testing.expectError(error.CollectionFull, c.add(
        alloc,
        .regular,
        .{ .loaded = try Face.init(
            lib,
            testFont,
            .{ .size = .{ .points = 12 } },
        ) },
    ));
}
