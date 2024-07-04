const std = @import("std");
const assert = std.debug.assert;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;
const pagepkg = @import("page.zig");
const size = @import("size.zig");
const Offset = size.Offset;
const Cell = pagepkg.Cell;
const Page = pagepkg.Page;
const RefCountedSet = @import("ref_counted_set.zig").RefCountedSet;
const Wyhash = std.hash.Wyhash;
const autoHash = std.hash.autoHash;
const autoHashStrat = std.hash.autoHashStrat;

/// The unique identifier for a hyperlink. This is at most the number of cells
/// that can fit in a single terminal page.
pub const Id = size.CellCountInt;

// The mapping of cell to hyperlink. We use an offset hash map to save space
// since its very unlikely a cell is a hyperlink, so its a waste to store
// the hyperlink ID in the cell itself.
pub const Map = AutoOffsetHashMap(Offset(Cell), Id);

/// The main entry for hyperlinks.
pub const Hyperlink = struct {
    id: Hyperlink.Id,
    uri: Offset(u8).Slice,

    pub const Id = union(enum) {
        /// An explicitly provided ID via the OSC8 sequence.
        explicit: Offset(u8).Slice,

        /// No ID was provided so we auto-generate the ID based on an
        /// incrementing counter attached to the screen.
        implicit: size.OffsetInt,
    };

    pub fn hash(self: *const Hyperlink, base: anytype) u64 {
        var hasher = Wyhash.init(0);
        autoHash(&hasher, std.meta.activeTag(self.id));
        switch (self.id) {
            .implicit => |v| autoHash(&hasher, v),
            .explicit => |slice| autoHashStrat(
                &hasher,
                slice.offset.ptr(base)[0..slice.len],
                .Deep,
            ),
        }
        autoHashStrat(
            &hasher,
            self.uri.offset.ptr(base)[0..self.uri.len],
            .Deep,
        );
        return hasher.final();
    }

    pub fn eql(self: *const Hyperlink, base: anytype, other: *const Hyperlink) bool {
        if (std.meta.activeTag(self.id) != std.meta.activeTag(other.id)) return false;
        switch (self.id) {
            .implicit => if (self.id.implicit != other.id.implicit) return false,
            .explicit => {
                const self_ptr = self.id.explicit.offset.ptr(base);
                const other_ptr = other.id.explicit.offset.ptr(base);
                if (!std.mem.eql(
                    u8,
                    self_ptr[0..self.id.explicit.len],
                    other_ptr[0..other.id.explicit.len],
                )) return false;
            },
        }

        return std.mem.eql(
            u8,
            self.uri.offset.ptr(base)[0..self.uri.len],
            other.uri.offset.ptr(base)[0..other.uri.len],
        );
    }
};

/// The set of hyperlinks. This is ref-counted so that a set of cells
/// can share the same hyperlink without duplicating the data.
pub const Set = RefCountedSet(
    Hyperlink,
    Id,
    size.CellCountInt,
    struct {
        page: ?*Page = null,

        pub fn hash(self: *const @This(), link: Hyperlink) u64 {
            return link.hash(self.page.?.memory);
        }

        pub fn eql(self: *const @This(), a: Hyperlink, b: Hyperlink) bool {
            return a.eql(self.page.?.memory, &b);
        }

        pub fn deleted(self: *const @This(), link: Hyperlink) void {
            const page = self.page.?;
            const alloc = &page.string_alloc;
            switch (link.id) {
                .implicit => {},
                .explicit => |v| alloc.free(
                    page.memory,
                    v.offset.ptr(page.memory)[0..v.len],
                ),
            }
            alloc.free(
                page.memory,
                link.uri.offset.ptr(page.memory)[0..link.uri.len],
            );
        }
    },
);
