const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const FontCollection = opaque {
    pub fn createFromAvailableFonts() Allocator.Error!*FontCollection {
        return @intToPtr(
            ?*FontCollection,
            @ptrToInt(c.CTFontCollectionCreateFromAvailableFonts(null)),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createWithFontDescriptors(descs: *foundation.Array) Allocator.Error!*FontCollection {
        return @intToPtr(
            ?*FontCollection,
            @ptrToInt(c.CTFontCollectionCreateWithFontDescriptors(
                @ptrCast(c.CFArrayRef, descs),
                null,
            )),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *FontCollection) void {
        c.CFRelease(self);
    }

    pub fn createMatchingFontDescriptors(self: *FontCollection) *foundation.Array {
        return @intToPtr(
            *foundation.Array,
            @ptrToInt(c.CTFontCollectionCreateMatchingFontDescriptors(
                @ptrCast(c.CTFontCollectionRef, self),
            )),
        );
    }
};

fn debugDumpList(list: *foundation.Array) !void {
    var i: usize = 0;
    while (i < list.getCount()) : (i += 1) {
        const desc = list.getValueAtIndex(text.FontDescriptor, i);
        {
            var buf: [128]u8 = undefined;
            const name = desc.copyAttribute(.name);
            defer name.release();
            const cstr = name.cstring(&buf, .utf8).?;

            var buf2: [128]u8 = undefined;
            const url = desc.copyAttribute(.url);
            defer url.release();
            const path = path: {
                const blank = try foundation.String.createWithBytes("", .utf8, false);
                defer blank.release();

                const path = url.copyPath() orelse break :path "<no path>";
                defer path.release();

                const decoded = try foundation.URL.createStringByReplacingPercentEscapes(
                    path,
                    blank,
                );
                defer decoded.release();

                break :path decoded.cstring(&buf2, .utf8) orelse
                    "<path cannot be converted to string>";
            };

            std.log.warn("i={d} name={s} path={s}", .{ i, cstr, path });
        }
    }
}

test "collection" {
    const testing = std.testing;

    const v = try FontCollection.createFromAvailableFonts();
    defer v.release();

    const list = v.createMatchingFontDescriptors();
    defer list.release();

    try testing.expect(list.getCount() > 0);
}

test "from descriptors" {
    const testing = std.testing;

    const name = try foundation.String.createWithBytes("AppleColorEmoji", .utf8, false);
    defer name.release();

    const desc = try text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();

    const arr = try foundation.Array.create(
        text.FontDescriptor,
        &[_]*const text.FontDescriptor{desc},
    );
    defer arr.release();

    const v = try FontCollection.createWithFontDescriptors(arr);
    defer v.release();

    const list = v.createMatchingFontDescriptors();
    defer list.release();

    try testing.expect(list.getCount() > 0);

    //try debugDumpList(list);
}
