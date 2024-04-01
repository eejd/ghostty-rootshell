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
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fontpkg = @import("main.zig");
const Discover = fontpkg.Discover;
const Style = fontpkg.Style;
const Library = fontpkg.Library;
const Metrics = fontpkg.face.Metrics;
const CodepointMap = fontpkg.CodepointMap;
const DesiredSize = fontpkg.face.DesiredSize;
const Face = fontpkg.Face;
const Group = fontpkg.Group;
const GroupCache = fontpkg.GroupCache;
const discovery = @import("discovery.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.font_group_cache_set);

/// The allocator to use for all heap allocations.
alloc: Allocator,

/// The map of font configurations to GroupCache instances.
map: Map = .{},

/// The font library that is used for all font groups.
font_lib: Library,

/// Font discovery mechanism.
font_discover: ?Discover = null,

/// Initialize a new GroupCacheSet.
pub fn init(alloc: Allocator) !GroupCacheSet {
    var font_lib = try Library.init();
    errdefer font_lib.deinit();

    return .{
        .alloc = alloc,
        .map = .{},
        .font_lib = font_lib,
    };
}

pub fn deinit(self: *GroupCacheSet) void {
    var it = self.map.iterator();
    while (it.next()) |entry| {
        entry.key_ptr.deinit();
        const ref = entry.value_ptr.*;
        ref.cache.deinit(self.alloc);
        self.alloc.destroy(ref.cache);
    }
    self.map.deinit(self.alloc);

    if (comptime Discover != void) {
        if (self.font_discover) |*v| v.deinit();
    }

    self.font_lib.deinit();
}

/// Initialize a GroupCache for the given font configuration. If the
/// GroupCache is not present it will be initialized with a ref count of
/// 1. If it is present, the ref count will be incremented.
///
/// This is NOT thread-safe.
pub fn groupRef(
    self: *GroupCacheSet,
    config: *const Config,
    font_size: DesiredSize,
) !struct { Key, *GroupCache } {
    var key = try Key.init(self.alloc, config);
    errdefer key.deinit();

    const gop = try self.map.getOrPut(self.alloc, key);
    if (gop.found_existing) {
        // We can deinit the key because we found a cached value.
        key.deinit();

        // Increment our ref count and return the cache
        gop.value_ptr.ref += 1;
        return .{ gop.key_ptr.*, gop.value_ptr.cache };
    }
    errdefer self.map.removeByPtr(gop.key_ptr);

    // A new font config, initialize the cache.
    const cache = try self.alloc.create(GroupCache);
    errdefer self.alloc.destroy(cache);
    gop.value_ptr.* = .{
        .cache = cache,
        .ref = 1,
    };

    cache.* = try GroupCache.init(self.alloc, group: {
        var group = try Group.init(self.alloc, self.font_lib, font_size);
        errdefer group.deinit();
        group.metric_modifiers = key.metric_modifiers;
        group.codepoint_map = key.codepoint_map;

        // Set our styles
        group.styles.set(.bold, config.@"font-style-bold" != .false);
        group.styles.set(.italic, config.@"font-style-italic" != .false);
        group.styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

        // Search for fonts
        if (Discover != void) discover: {
            const disco = try self.discover() orelse {
                log.warn("font discovery not available, cannot search for fonts", .{});
                break :discover;
            };
            group.discover = disco;

            // A buffer we use to store the font names for logging.
            var name_buf: [256]u8 = undefined;

            inline for (@typeInfo(Style).Enum.fields) |field| {
                const style = @field(Style, field.name);
                for (key.descriptorsForStyle(style)) |desc| {
                    var disco_it = try disco.discover(self.alloc, desc);
                    defer disco_it.deinit();
                    if (try disco_it.next()) |face| {
                        log.info("font {s}: {s}", .{
                            field.name,
                            try face.name(&name_buf),
                        });
                        _ = try group.addFace(style, .{ .deferred = face });
                    } else log.warn("font-family {s} not found: {s}", .{
                        field.name,
                        desc.family.?,
                    });
                }
            }
        }

        // Our built-in font will be used as a backup
        _ = try group.addFace(
            .regular,
            .{ .fallback_loaded = try Face.init(
                self.font_lib,
                face_ttf,
                group.faceOptions(),
            ) },
        );
        _ = try group.addFace(
            .bold,
            .{ .fallback_loaded = try Face.init(
                self.font_lib,
                face_bold_ttf,
                group.faceOptions(),
            ) },
        );

        // Auto-italicize if we have to.
        try group.italicize();

        // On macOS, always search for and add the Apple Emoji font
        // as our preferred emoji font for fallback. We do this in case
        // people add other emoji fonts to their system, we always want to
        // prefer the official one. Users can override this by explicitly
        // specifying a font-family for emoji.
        if (comptime builtin.target.isDarwin()) apple_emoji: {
            const disco = group.discover orelse break :apple_emoji;
            var disco_it = try disco.discover(self.alloc, .{
                .family = "Apple Color Emoji",
            });
            defer disco_it.deinit();
            if (try disco_it.next()) |face| {
                _ = try group.addFace(.regular, .{ .fallback_deferred = face });
            }
        }

        // Emoji fallback. We don't include this on Mac since Mac is expected
        // to always have the Apple Emoji available on the system.
        if (comptime !builtin.target.isDarwin() or Discover == void) {
            _ = try group.addFace(
                .regular,
                .{ .fallback_loaded = try Face.init(
                    self.font_lib,
                    face_emoji_ttf,
                    group.faceOptions(),
                ) },
            );
            _ = try group.addFace(
                .regular,
                .{ .fallback_loaded = try Face.init(
                    self.font_lib,
                    face_emoji_text_ttf,
                    group.faceOptions(),
                ) },
            );
        }

        log.info("font loading complete, any non-logged faces are using the built-in font", .{});
        break :group group;
    });
    errdefer cache.deinit(self.alloc);

    return .{ gop.key_ptr.*, gop.value_ptr.cache };
}

/// Decrement the ref count for the given key. If the ref count is zero,
/// the GroupCache will be deinitialized and removed from the map.j:w
pub fn groupDeref(self: *GroupCacheSet, key: Key) void {
    const entry = self.map.getEntry(key) orelse return;
    assert(entry.value_ptr.ref >= 1);

    // If we have more than one reference, decrement and return.
    if (entry.value_ptr.ref > 1) {
        entry.value_ptr.ref -= 1;
        return;
    }

    // We are at a zero ref count so deinit the group and remove.
    entry.key_ptr.deinit();
    entry.value_ptr.cache.deinit(self.alloc);
    self.alloc.destroy(entry.value_ptr.cache);
    self.map.removeByPtr(entry.key_ptr);
}

/// Map of font configurations to GroupCache instances. The GroupCache
/// instances are pointers that are heap allocated so that they're
/// stable pointers across hash map resizes.
pub const Map = std.HashMapUnmanaged(
    Key,
    RefGroupCache,
    struct {
        const KeyType = Key;

        pub fn hash(ctx: @This(), k: KeyType) u64 {
            _ = ctx;
            return k.hashcode();
        }

        pub fn eql(ctx: @This(), a: KeyType, b: KeyType) bool {
            return ctx.hash(a) == ctx.hash(b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

/// Initialize once and return the font discovery mechanism. This remains
/// initialized throughout the lifetime of the application because some
/// font discovery mechanisms (i.e. fontconfig) are unsafe to reinit.
fn discover(self: *GroupCacheSet) !?*Discover {
    // If we're built without a font discovery mechanism, return null
    if (comptime Discover == void) return null;

    // If we initialized, use it
    if (self.font_discover) |*v| return v;

    self.font_discover = Discover.init();
    return &self.font_discover.?;
}

/// Ref-counted GroupCache.
const RefGroupCache = struct {
    cache: *GroupCache,
    ref: u32 = 0,
};

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

    /// The metric modifier set configuration.
    metric_modifiers: Metrics.ModifierSet,

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

        // Metric modifiers
        const metric_modifiers: Metrics.ModifierSet = set: {
            var set: Metrics.ModifierSet = .{};
            if (config.@"adjust-cell-width") |m| try set.put(alloc, .cell_width, m);
            if (config.@"adjust-cell-height") |m| try set.put(alloc, .cell_height, m);
            if (config.@"adjust-font-baseline") |m| try set.put(alloc, .cell_baseline, m);
            if (config.@"adjust-underline-position") |m| try set.put(alloc, .underline_position, m);
            if (config.@"adjust-underline-thickness") |m| try set.put(alloc, .underline_thickness, m);
            if (config.@"adjust-strikethrough-position") |m| try set.put(alloc, .strikethrough_position, m);
            if (config.@"adjust-strikethrough-thickness") |m| try set.put(alloc, .strikethrough_thickness, m);
            break :set set;
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
            .metric_modifiers = metric_modifiers,
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
        autoHash(hasher, self.metric_modifiers.count());
        if (self.metric_modifiers.count() > 0) {
            inline for (@typeInfo(Metrics.Key).Enum.fields) |field| {
                const key = @field(Metrics.Key, field.name);
                if (self.metric_modifiers.get(key)) |value| {
                    autoHash(hasher, key);
                    value.hash(hasher);
                }
            }
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }
};

const face_ttf = @embedFile("res/JetBrainsMono-Regular.ttf");
const face_bold_ttf = @embedFile("res/JetBrainsMono-Bold.ttf");
const face_emoji_ttf = @embedFile("res/NotoColorEmoji.ttf");
const face_emoji_text_ttf = @embedFile("res/NotoEmoji-Regular.ttf");

test "Key" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var k = try Key.init(alloc, &cfg);
    defer k.deinit();

    try testing.expect(k.hashcode() > 0);
}

test "basics" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set = try GroupCacheSet.init(alloc);
    defer set.deinit();
}
