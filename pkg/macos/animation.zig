const std = @import("std");

pub const c = @import("animation/c.zig").c;

/// https://developer.apple.com/documentation/quartzcore/calayer/contents_gravity_values?language=objc
pub extern "c" const kCAGravityTopLeft: *anyopaque;
pub extern "c" const kCAGravityBottomLeft: *anyopaque;
pub extern "c" const kCAGravityCenter: *anyopaque;

/// CADynamicRange values for `CALayer.preferredDynamicRange` (the 2025 OS
/// releases / "26"+). NSString-backed constants (the property is
/// `@property(copy)`), so they're passed as objects, not integers.
/// https://developer.apple.com/documentation/quartzcore/calayer/preferreddynamicrange
///
/// Looked up via `dlsym` rather than a (weak) `extern const`: these symbols
/// don't exist before the 2025 OS releases, so a strong reference makes dyld
/// abort at launch on iOS <26 — but a *weak* `@extern` isn't safe either,
/// because the optimizer assumes the address of an extern symbol is non-null
/// and elides the null guard, so it still dereferences a null address (and
/// crashes) on systems where the symbol is absent. `dlsym` returns a genuine
/// runtime value the optimizer can't assume away, and removes the link-time
/// symbol entirely. Returns null when the symbol is absent; callers MUST bail
/// in that case (see IOSurfaceLayer.setPreferredDynamicRange).
pub fn caDynamicRangeStandard() ?*anyopaque {
    return dynamicRangeConstant("CADynamicRangeStandard");
}

pub fn caDynamicRangeHigh() ?*anyopaque {
    return dynamicRangeConstant("CADynamicRangeHigh");
}

fn dynamicRangeConstant(name: [*:0]const u8) ?*anyopaque {
    // RTLD_DEFAULT (Darwin) = (void *)-2; searches all loaded images.
    const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    const addr = std.c.dlsym(RTLD_DEFAULT, name) orelse return null;
    // dlsym yields the *address of* the symbol; deref to read the NSString value.
    const slot: *const ?*anyopaque = @ptrCast(@alignCast(addr));
    return slot.*;
}

test {
    @import("std").testing.refAllDecls(@This());
}
