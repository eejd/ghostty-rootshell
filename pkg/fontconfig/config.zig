const std = @import("std");
const c = @import("c.zig");
const FontSet = @import("font_set.zig").FontSet;
const ObjectSet = @import("object_set.zig").ObjectSet;
const Pattern = @import("pattern.zig").Pattern;

pub const Config = opaque {
    pub fn destroy(self: *Config) void {
        c.FcConfigDestroy(@ptrCast(*c.struct__FcConfig, self));
    }

    pub fn list(self: *Config, pat: *Pattern, os: *ObjectSet) *FontSet {
        return @ptrCast(*FontSet, c.FcFontList(self.cval(), pat.cval(), os.cval()));
    }

    pub inline fn cval(self: *Config) *c.struct__FcConfig {
        return @ptrCast(*c.struct__FcConfig, self);
    }
};
