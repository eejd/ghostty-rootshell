const builtin = @import("builtin");

extern "c" fn hwy_supported_targets() i64;

pub const Targets = @import("targets.zig").Targets;

pub fn supported_targets() Targets {
    return @bitCast(hwy_supported_targets());
}

test {
    _ = supported_targets();
    if (builtin.os.tag.isDarwin()) {
        _ = @import("runtime_darwin.zig");
    }
}
