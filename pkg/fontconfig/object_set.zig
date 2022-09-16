const std = @import("std");
const c = @import("c.zig");

pub const ObjectSet = opaque {
    pub fn create() *ObjectSet {
        return @ptrCast(*ObjectSet, c.FcObjectSetCreate());
    }

    pub fn destroy(self: *ObjectSet) void {
        c.FcObjectSetDestroy(self.cval());
    }

    pub fn add(self: *ObjectSet, p: Property) bool {
        return c.FcObjectSetAdd(self.cval(), p.cval().ptr) == c.FcTrue;
    }

    pub inline fn cval(self: *ObjectSet) *c.struct__FcObjectSet {
        return @ptrCast(
            *c.struct__FcObjectSet,
            @alignCast(@alignOf(c.struct__FcObjectSet), self),
        );
    }
};

pub const Property = enum {
    family,
    style,
    slant,
    weight,
    size,
    aspect,
    pixel_size,
    spacing,
    foundry,
    antialias,
    hinting,
    hint_style,
    vertical_layout,
    autohint,
    global_advance,
    width,
    file,
    index,
    ft_face,
    rasterizer,
    outline,
    scalable,
    color,
    variable,
    scale,
    symbol,
    dpi,
    rgba,
    minspace,
    source,
    charset,
    lang,
    fontversion,
    fullname,
    familylang,
    stylelang,
    fullnamelang,
    capability,
    embolden,
    embedded_bitmap,
    decorative,
    lcd_filter,
    font_features,
    font_variations,
    namelang,
    prgname,
    hash,
    postscript_name,
    font_has_hint,
    order,

    pub fn cval(self: Property) [:0]const u8 {
        @setEvalBranchQuota(10_000);
        inline for (@typeInfo(Property).Enum.fields) |field| {
            if (self == @field(Property, field.name)) {
                // Build our string in a comptime context so it is a binary
                // constant and not stack allocated.
                return comptime name: {
                    // Replace _ with ""
                    var buf: [field.name.len]u8 = undefined;
                    const count = std.mem.replace(u8, field.name, "_", "", &buf);
                    const replaced = buf[0 .. field.name.len - count];

                    // Build our string
                    var name: [replaced.len:0]u8 = undefined;
                    std.mem.copy(u8, &name, replaced);
                    name[replaced.len] = 0;
                    break :name &name;
                };
            }
        }

        unreachable;
    }

    test "cval" {
        const testing = std.testing;
        try testing.expectEqualStrings("family", Property.family.cval());
        try testing.expectEqualStrings("pixelsize", Property.pixel_size.cval());
    }
};

test "create" {
    const testing = std.testing;

    var os = ObjectSet.create();
    defer os.destroy();

    try testing.expect(os.add(.family));
}
