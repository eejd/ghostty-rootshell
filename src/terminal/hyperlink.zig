const std = @import("std");
const assert = std.debug.assert;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;
const size = @import("size.zig");
const Offset = size.Offset;
const Cell = @import("page.zig").Cell;
const RefCountedSet = @import("ref_counted_set.zig").RefCountedSet;

/// The unique identifier for a hyperlink. This is at most the number of cells
/// that can fit in a single terminal page.
pub const Id = size.CellCountInt;

// The mapping of cell to hyperlink. We use an offset hash map to save space
// since its very unlikely a cell is a hyperlink, so its a waste to store
// the hyperlink ID in the cell itself.
pub const Map = AutoOffsetHashMap(Offset(Cell), Id);

/// The main entry for hyperlinks.
pub const Hyperlink = struct {
    id: union(enum) {
        /// An explicitly provided ID via the OSC8 sequence.
        explicit: Offset(u8).Slice,

        /// No ID was provided so we auto-generate the ID based on an
        /// incrementing counter. TODO: implement the counter
        implicit: size.OffsetInt,
    },

    /// The URI for the actual link.
    uri: Offset(u8).Slice,
};

/// The set of hyperlinks. This is ref-counted so that a set of cells
/// can share the same hyperlink without duplicating the data.
pub const Set = RefCountedSet(
    Hyperlink,
    Id,
    size.CellCountInt,
    struct {
        pub fn hash(self: *const @This(), link: Hyperlink) u64 {
            _ = self;
            return link.hash();
        }

        pub fn eql(self: *const @This(), a: Hyperlink, b: Hyperlink) bool {
            _ = self;
            return a.eql(b);
        }
    },
);
