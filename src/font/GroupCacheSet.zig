//! This structure contains a set of GroupCache instances keyed by
//! unique font configuration.
//!
//! Most terminals (surfaces) will share the same font configuration.
//! This structure allows expensive font information such as
//! the font atlas, glyph cache, font faces, etc. to be shared.
//!
//! The Ghostty renderers which use this information run on their
//! own threads so this structure is thread-safe. It expects that
//! the case where all glyphs are cached is the common case and
//! optimizes for that. When a glyph is not cached, all renderers
//! that share the same font configuration will be blocked until
//! the glyph is cached.
const GroupCacheSet = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fontpkg = @import("main.zig");
const Style = fontpkg.Style;
const CodepointMap = fontpkg.CodepointMap;
const discovery = @import("discovery.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

/// The key used to uniquely identify a font configuration.
pub const Key = struct {
    arena: ArenaAllocator,

    /// The descriptors used for all the fonts added to the
    /// initial group, including all styles. This is hashed
    /// in order so the order matters. All users of the struct
    /// should ensure that the order is consistent.
    descriptors: []const discovery.Descriptor,

    /// These are the offsets into the descriptors array for
    /// each style. For example, bold is from
    /// offsets[@intFromEnum(.bold) - 1] to
    /// offsets[@intFromEnum(.bold)].
    style_offsets: StyleOffsets = .{0} ** style_offsets_len,

    /// The codepoint map configuration.
    codepoint_map: CodepointMap,

    const style_offsets_len = std.enums.directEnumArrayLen(Style, 0);
    const StyleOffsets = [style_offsets_len]usize;

    comptime {
        // We assume this throughout this structure. If this changes
        // we may need to change this structure.
        assert(@intFromEnum(Style.regular) == 0);
        assert(@intFromEnum(Style.bold) == 1);
        assert(@intFromEnum(Style.italic) == 2);
        assert(@intFromEnum(Style.bold_italic) == 3);
    }

    pub fn init(
        alloc_gpa: Allocator,
        config: *const Config,
    ) !Key {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var descriptors = std.ArrayList(discovery.Descriptor).init(alloc);
        defer descriptors.deinit();
        for (config.@"font-family".list.items) |family| {
            try descriptors.append(.{
                .family = family,
                .style = config.@"font-style".nameValue(),
                .size = config.@"font-size",
                .variations = config.@"font-variation".list.items,
            });
        }

        // In all the styled cases below, we prefer to specify an exact
        // style via the `font-style` configuration. If a style is not
        // specified, we use the discovery mechanism to search for a
        // style category such as bold, italic, etc. We can't specify both
        // because the latter will restrict the search to only that. If
        // a user says `font-style = italic` for the bold face for example,
        // no results would be found if we restrict to ALSO searching for
        // italic.
        for (config.@"font-family-bold".list.items) |family| {
            const style = config.@"font-style-bold".nameValue();
            try descriptors.append(.{
                .family = family,
                .style = style,
                .size = config.@"font-size",
                .bold = style == null,
                .variations = config.@"font-variation".list.items,
            });
        }
        for (config.@"font-family-italic".list.items) |family| {
            const style = config.@"font-style-italic".nameValue();
            try descriptors.append(.{
                .family = family,
                .style = style,
                .size = config.@"font-size",
                .italic = style == null,
                .variations = config.@"font-variation".list.items,
            });
        }
        for (config.@"font-family-bold-italic".list.items) |family| {
            const style = config.@"font-style-bold-italic".nameValue();
            try descriptors.append(.{
                .family = family,
                .style = style,
                .size = config.@"font-size",
                .bold = style == null,
                .italic = style == null,
                .variations = config.@"font-variation".list.items,
            });
        }

        // Setup the codepoint map
        const codepoint_map: CodepointMap = map: {
            const map = config.@"font-codepoint-map";
            if (map.map.list.len == 0) break :map .{};
            const clone = try config.@"font-codepoint-map".clone(alloc);
            break :map clone.map;
        };

        return .{
            .arena = arena,
            .descriptors = try descriptors.toOwnedSlice(),
            .style_offsets = .{
                config.@"font-family".list.items.len,
                config.@"font-family-bold".list.items.len,
                config.@"font-family-italic".list.items.len,
                config.@"font-family-bold-italic".list.items.len,
            },
            .codepoint_map = codepoint_map,
        };
    }

    pub fn deinit(self: *Key) void {
        self.arena.deinit();
    }

    /// Get the descriptors for the given font style that can be
    /// used with discovery.
    pub fn descriptorsForStyle(
        self: Key,
        style: Style,
    ) []const discovery.Descriptor {
        const idx = @intFromEnum(style);
        const start: usize = if (idx == 0) 0 else self.style_offsets[idx - 1];
        const end = self.style_offsets[idx];
        return self.descriptors[start..end];
    }

    /// Hash the key with the given hasher.
    pub fn hash(self: Key, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        autoHash(hasher, self.descriptors.len);
        for (self.descriptors) |d| d.hash(hasher);
        autoHash(hasher, self.codepoint_map);
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }
};

test "Key" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var k = try Key.init(alloc, &cfg);
    defer k.deinit();
}
