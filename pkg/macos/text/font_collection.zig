const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");

pub const FontCollection = opaque {
    pub fn createFromAvailableFonts() Allocator.Error!*FontCollection {
        return CTFontCollectionCreateFromAvailableFonts(null) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *FontCollection) void {
        foundation.CFRelease(self);
    }

    pub extern "c" fn CTFontCollectionCreateFromAvailableFonts(
        options: ?*foundation.Dictionary,
    ) ?*FontCollection;
};

test "collection" {
    const v = try FontCollection.createFromAvailableFonts();
    defer v.release();
}
