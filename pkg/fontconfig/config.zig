const std = @import("std");
const c = @import("c.zig");
const CharSet = @import("char_set.zig").CharSet;
const FontSet = @import("font_set.zig").FontSet;
const ObjectSet = @import("object_set.zig").ObjectSet;
const Pattern = @import("pattern.zig").Pattern;
const Result = @import("main.zig").Result;
const MatchKind = @import("main.zig").MatchKind;

pub const Config = opaque {
    pub fn destroy(self: *Config) void {
        c.FcConfigDestroy(@ptrCast(*c.struct__FcConfig, self));
    }

    pub fn fontList(self: *Config, pat: *Pattern, os: *ObjectSet) *FontSet {
        return @ptrCast(*FontSet, c.FcFontList(self.cval(), pat.cval(), os.cval()));
    }

    pub fn fontSort(
        self: *Config,
        pat: *Pattern,
        trim: bool,
        charset: ?[*]*CharSet,
    ) FontSortResult {
        var result: FontSortResult = undefined;
        result.fs = @ptrCast(*FontSet, c.FcFontSort(
            self.cval(),
            pat.cval(),
            if (trim) c.FcTrue else c.FcFalse,
            @ptrCast([*c]?*c.struct__FcCharSet, charset),
            @ptrCast([*c]c_uint, &result.result),
        ));

        return result;
    }

    pub fn fontRenderPrepare(self: *Config, pat: *Pattern, font: *Pattern) *Pattern {
        return @ptrCast(*Pattern, c.FcFontRenderPrepare(self.cval(), pat.cval(), font.cval()));
    }

    pub fn substituteWithPat(self: *Config, pat: *Pattern, kind: MatchKind) bool {
        return c.FcConfigSubstitute(
            self.cval(),
            pat.cval(),
            @enumToInt(kind),
        ) == c.FcTrue;
    }

    pub inline fn cval(self: *Config) *c.struct__FcConfig {
        return @ptrCast(*c.struct__FcConfig, self);
    }
};

pub const FontSortResult = struct {
    result: Result,
    fs: *FontSet,
};
