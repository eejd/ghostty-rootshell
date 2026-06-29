pub const c = @import("animation/c.zig").c;

/// https://developer.apple.com/documentation/quartzcore/calayer/contents_gravity_values?language=objc
pub extern "c" const kCAGravityTopLeft: *anyopaque;
pub extern "c" const kCAGravityBottomLeft: *anyopaque;
pub extern "c" const kCAGravityCenter: *anyopaque;

/// CADynamicRange values for `CALayer.preferredDynamicRange` (iOS/macOS 26+).
/// These are NSString-backed constants (the property is `@property(copy)`), so
/// they're passed as objects, not integers.
/// https://developer.apple.com/documentation/quartzcore/calayer/preferreddynamicrange
pub extern "c" const CADynamicRangeStandard: *anyopaque;
pub extern "c" const CADynamicRangeHigh: *anyopaque;

test {
    @import("std").testing.refAllDecls(@This());
}
