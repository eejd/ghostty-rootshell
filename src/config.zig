pub const Config = @import("config/Config.zig");
pub const Key = @import("config/key.zig").Key;

// Field types
pub const CopyOnSelect = Config.CopyOnSelect;
pub const Keybinds = Config.Keybinds;
pub const NonNativeFullscreen = Config.NonNativeFullscreen;
pub const OptionAsAlt = Config.OptionAsAlt;

// Alternate APIs
pub const CAPI = @import("config/CAPI.zig");
pub const Wasm = @import("config/Wasm.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
