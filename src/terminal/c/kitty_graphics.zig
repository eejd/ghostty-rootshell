const build_options = @import("terminal_options");
const kitty_gfx = @import("../kitty/graphics_storage.zig");

/// C: GhosttyKittyGraphics
pub const KittyGraphics = if (build_options.kitty_graphics)
    *kitty_gfx.ImageStorage
else
    *anyopaque;
