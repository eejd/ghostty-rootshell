const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const FontDescriptor = opaque {
    pub fn createWithNameAndSize(name: *foundation.String, size: f64) Allocator.Error!*FontDescriptor {
        return @intToPtr(
            ?*FontDescriptor,
            @ptrToInt(c.CTFontDescriptorCreateWithNameAndSize(@ptrCast(c.CFStringRef, name), size)),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *FontDescriptor) void {
        c.CFRelease(self);
    }

    pub fn copyAttribute(self: *FontDescriptor, comptime attr: FontAttribute) attr.Value() {
        return @intToPtr(attr.Value(), @ptrToInt(c.CTFontDescriptorCopyAttribute(
            @ptrCast(c.CTFontDescriptorRef, self),
            @ptrCast(c.CFStringRef, attr.key()),
        )));
    }
};

pub const FontAttribute = enum {
    url,
    name,
    display_name,
    family_name,
    style_name,
    traits,
    variation,
    size,
    matrix,
    cascade_list,
    character_set,
    languages,
    baseline_adjust,
    macintosh_encodings,
    features,
    feature_settings,
    fixed_advance,
    orientation,
    format,
    registration_scope,
    priority,
    enabled,
    downloadable,
    downloaded,

    pub fn key(self: FontAttribute) *foundation.String {
        return @intToPtr(*foundation.String, @ptrToInt(switch (self) {
            .url => c.kCTFontURLAttribute,
            .name => c.kCTFontNameAttribute,
            .display_name => c.kCTFontDisplayNameAttribute,
            .family_name => c.kCTFontFamilyNameAttribute,
            .style_name => c.kCTFontStyleNameAttribute,
            .traits => c.kCTFontTraitsAttribute,
            .variation => c.kCTFontVariationAttribute,
            .size => c.kCTFontSizeAttribute,
            .matrix => c.kCTFontMatrixAttribute,
            .cascade_list => c.kCTFontCascadeListAttribute,
            .character_set => c.kCTFontCharacterSetAttribute,
            .languages => c.kCTFontLanguagesAttribute,
            .baseline_adjust => c.kCTFontBaselineAdjustAttribute,
            .macintosh_encodings => c.kCTFontMacintoshEncodingsAttribute,
            .features => c.kCTFontFeaturesAttribute,
            .feature_settings => c.kCTFontFeatureSettingsAttribute,
            .fixed_advance => c.kCTFontFixedAdvanceAttribute,
            .orientation => c.kCTFontOrientationAttribute,
            .format => c.kCTFontFormatAttribute,
            .registration_scope => c.kCTFontRegistrationScopeAttribute,
            .priority => c.kCTFontPriorityAttribute,
            .enabled => c.kCTFontEnabledAttribute,
            .downloadable => c.kCTFontDownloadableAttribute,
            .downloaded => c.kCTFontDownloadedAttribute,
        }));
    }

    pub fn Value(self: FontAttribute) type {
        return switch (self) {
            .url => *foundation.URL,
            .name => *foundation.String,
            .display_name => *foundation.String,
            .family_name => *foundation.String,
            .style_name => *foundation.String,
            .traits => *foundation.Dictionary,
            .variation => *foundation.Dictionary,
            .size => *anyopaque, // CFNumber
            .matrix => *anyopaque, // CFDataRef
            .cascade_list => *foundation.Array,
            .character_set => *anyopaque, // CFCharacterSetRef
            .languages => *foundation.Array,
            .baseline_adjust => *anyopaque, // CFNumber
            .macintosh_encodings => *anyopaque, // CFNumber
            .features => *foundation.Array,
            .feature_settings => *foundation.Array,
            .fixed_advance => *anyopaque, // CFNumber
            .orientation => *anyopaque, // CFNumber
            .format => *anyopaque, // CFNumber
            .registration_scope => *anyopaque, // CFNumber
            .priority => *anyopaque, // CFNumber
            .enabled => *anyopaque, // CFNumber
            .downloadable => *anyopaque, // CFBoolean
            .downloaded => *anyopaque, // CFBoolean
        };
    }
};

test "descriptor" {
    const testing = std.testing;

    const name = try foundation.String.createWithBytes("foo", .utf8, false);
    defer name.release();

    const v = try FontDescriptor.createWithNameAndSize(name, 12);
    defer v.release();

    const copy_name = v.copyAttribute(.name);
    defer copy_name.release();

    {
        var buf: [128]u8 = undefined;
        const cstr = copy_name.cstring(&buf, .utf8).?;
        try testing.expectEqualStrings("foo", cstr);
    }
}
