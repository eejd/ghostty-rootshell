const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const StringAttribute = enum {
    font,

    pub fn key(self: StringAttribute) *foundation.String {
        return @intToPtr(*foundation.String, @ptrToInt(switch (self) {
            .font => c.kCTFontAttributeName,
        }));
    }
};
