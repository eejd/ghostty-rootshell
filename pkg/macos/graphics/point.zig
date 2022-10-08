const c = @import("c.zig");

pub const Point = extern struct {
    x: c.CGFloat,
    y: c.CGFloat,

    pub fn cval(self: Point) c.struct_CGPoint {
        return @bitCast(c.struct_CGPoint, self);
    }
};
