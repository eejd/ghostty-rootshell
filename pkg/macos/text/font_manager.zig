const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub fn createFontDescriptorsFromURL(url: *foundation.URL) ?*foundation.Array {
    return @ptrFromInt(
        ?*foundation.Array,
        @intFromPtr(c.CTFontManagerCreateFontDescriptorsFromURL(
            @ptrCast(c.CFURLRef, url),
        )),
    );
}

pub fn createFontDescriptorsFromData(data: *foundation.Data) ?*foundation.Array {
    return @ptrFromInt(
        ?*foundation.Array,
        @intFromPtr(c.CTFontManagerCreateFontDescriptorsFromData(
            @ptrCast(c.CFDataRef, data),
        )),
    );
}
