const std = @import("std");
const builtin = @import("builtin");

/// Returns true if we're running in a Flatpak environment.
pub fn isFlatpak() bool {
    // If we're not on Linux then we'll make this comptime false.
    if (comptime builtin.os.tag != .linux) return false;
    return if (std.fs.accessAbsolute("/.flatpak-info", .{})) true else |_| false;
}
