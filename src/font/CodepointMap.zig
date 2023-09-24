/// CodepointMap is a map of codepoints to a discovery descriptor of a font
/// to use for that codepoint. If the descriptor doesn't return any matching
/// font, the codepoint is rendered using the default font.
const CodepointMap = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const discovery = @import("discovery.zig");

pub const Entry = struct {
    /// Unicode codepoint range. Asserts range[0] <= range[1].
    range: [2]u21,

    /// The discovery descriptor of the font to use for this range.
    descriptor: discovery.Descriptor,
};

/// The list of entries. We use a multiarraylist because Descriptors are
/// quite large and we will very rarely match, so we'd rather pack our
/// ranges together to make everything more cache friendly for lookups.
///
/// Note: we just do a linear search because we expect to always have very
/// few entries, so the overhead of a binary search is not worth it. This is
/// possible to defeat with some pathological inputs, but there is no realistic
/// scenario where this will be a problem except people trying to fuck around.
list: std.MultiArrayList(Entry) = .{},

/// Add an entry to the map.
///
/// For conflicting codepoints, entries added later take priority over
/// entries added earlier.
pub fn add(self: *CodepointMap, alloc: Allocator, entry: Entry) !void {
    assert(entry.range[0] <= entry.range[1]);
    try self.list.append(alloc, entry);
}

/// Get a descriptor for a codepoint.
pub fn get(self: *const CodepointMap, cp: u21) ?discovery.Descriptor {
    for (self.list.items(.range), 0..) |range, i| {
        if (range[0] <= cp and cp <= range[1]) {
            const descs = self.list.items(.descriptor);
            return descs[i];
        }
    }

    return null;
}
