const c = @import("c.zig");

pub const Encoding = opaque {
    pub const utf8: *Encoding = @ptrCast(c.ONIG_ENCODING_UTF8);
};
