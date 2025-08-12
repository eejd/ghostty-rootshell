const config = @import("config.zig");
const config_x = @import("config.x.zig");
const d = config.default;
const wcwidth = config_x.wcwidth;

pub const tables = [_]config.Table{
    .{
        .extensions = &.{wcwidth},
        .fields = &.{
            wcwidth.field("wcwidth"),
            d.field("general_category"),
            d.field("has_emoji_presentation"),
            d.field("block"),
        },
    },
};
