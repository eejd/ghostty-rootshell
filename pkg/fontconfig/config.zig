const std = @import("std");
const c = @import("c.zig");

pub const Config = opaque {
    pub fn destroy(self: *Config) void {
        c.FcConfigDestroy(@ptrCast(*c.struct__FcConfig, self));
    }
};
