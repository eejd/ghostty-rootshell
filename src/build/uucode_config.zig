const config = @import("config.zig");
const x = @import("uucode.x.config");
const d = config.default;

pub const tables = [_]config.Table{
    .{
        .extensions = &.{x.wcwidth},
        .fields = &.{
            x.wcwidth.field("wcwidth"),
            d.field("general_category"),
            d.field("has_emoji_presentation"),
        },
    },
};
