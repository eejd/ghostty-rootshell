const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub fn createFontDescriptorsFromURL(url: *foundation.URL) ?*foundation.Array {
    return @intToPtr(
        ?*foundation.Array,
        @ptrToInt(c.CTFontManagerCreateFontDescriptorsFromURL(
            @ptrCast(c.CFURLRef, url),
        )),
    );
}
