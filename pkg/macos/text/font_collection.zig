const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const text = @import("../text.zig");

pub const FontCollection = opaque {
    pub fn createFromAvailableFonts() Allocator.Error!*FontCollection {
        return CTFontCollectionCreateFromAvailableFonts(null) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *FontCollection) void {
        foundation.CFRelease(self);
    }

    pub fn createMatchingFontDescriptors(self: *FontCollection) *foundation.Array {
        return CTFontCollectionCreateMatchingFontDescriptors(self);
    }

    pub extern "c" fn CTFontCollectionCreateFromAvailableFonts(
        options: ?*foundation.Dictionary,
    ) ?*FontCollection;
    pub extern "c" fn CTFontCollectionCreateMatchingFontDescriptors(
        collection: *FontCollection,
    ) *foundation.Array;
};

test "collection" {
    const testing = std.testing;

    const v = try FontCollection.createFromAvailableFonts();
    defer v.release();

    const list = v.createMatchingFontDescriptors();
    defer list.release();

    try testing.expect(list.getCount() > 0);

    // var i: usize = 0;
    // while (i < list.getCount()) : (i += 1) {
    //     const desc = list.getValueAtIndex(text.FontDescriptor, i);
    //     {
    //         var buf: [128]u8 = undefined;
    //         const name = desc.copyAttribute(.name);
    //         defer name.release();
    //         const cstr = name.cstring(&buf, .utf8).?;
    //         std.log.warn("i={d} v={s}", .{ i, cstr });
    //     }
    // }
}
