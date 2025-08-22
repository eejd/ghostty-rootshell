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
            d.field("block"),
            d.field("is_emoji_presentation"),
            d.field("case_folding_full"),
            // Alternative:
            // d.field("case_folding_simple"),
            d.field("grapheme_break"),
            d.field("is_emoji_modifier"),
            d.field("is_emoji_modifier_base"),
        },
    },
};
