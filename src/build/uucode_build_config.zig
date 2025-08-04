const config = @import("config.zig");
const x = @import("uucode.x.config");
const d = config.default;

pub const tables = [_]config.Table{
    .{
        .extensions = &.{x.width},
        .fields = &.{
            x.width.field("width"),
            d.field("general_category"),
            d.field("has_emoji_presentation"),
        },
    },
};
