const c = @import("c.zig");

pub const Point = extern struct {
    x: c.CGFloat,
    y: c.CGFloat,

    pub fn cval(self: Point) c.struct_CGPoint {
        return @bitCast(c.struct_CGPoint, self);
    }
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn cval(self: Rect) c.struct_CGRect {
        return @bitCast(c.struct_CGRect, self);
    }
};

pub const Size = extern struct {
    width: c.CGFloat,
    height: c.CGFloat,

    pub fn cval(self: Size) c.struct_CGSize {
        return @bitCast(c.struct_CGSize, self);
    }
};
