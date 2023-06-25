const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const StringAttribute = enum {
    font,

    pub fn key(self: StringAttribute) *foundation.String {
        return @ptrFromInt(*foundation.String, @intFromPtr(switch (self) {
            .font => c.kCTFontAttributeName,
        }));
    }
};
