const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");

pub const FontDescriptor = opaque {
    pub fn createWithNameAndSize(name: *foundation.String, size: f64) Allocator.Error!*FontDescriptor {
        return CTFontDescriptorCreateWithNameAndSize(name, size) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *FontDescriptor) void {
        foundation.CFRelease(self);
    }

    pub fn copyAttribute(self: *FontDescriptor, comptime attr: FontAttribute) attr.Value() {
        const T = attr.Value();
        return @ptrCast(T, CTFontDescriptorCopyAttribute(self, attr.key()));
    }

    pub extern "c" fn CTFontDescriptorCreateWithNameAndSize(
        name: *foundation.String,
        size: f64,
    ) ?*FontDescriptor;
    pub extern "c" fn CTFontDescriptorCopyAttribute(
        *FontDescriptor,
        *foundation.String,
    ) ?*anyopaque;
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
        return switch (self) {
            .url => kCTFontURLAttribute,
            .name => kCTFontNameAttribute,
            .display_name => kCTFontDisplayNameAttribute,
            .family_name => kCTFontFamilyNameAttribute,
            .style_name => kCTFontStyleNameAttribute,
            .traits => kCTFontTraitsAttribute,
            .variation => kCTFontVariationAttribute,
            .size => kCTFontSizeAttribute,
            .matrix => kCTFontMatrixAttribute,
            .cascade_list => kCTFontCascadeListAttribute,
            .character_set => kCTFontCharacterSetAttribute,
            .languages => kCTFontLanguagesAttribute,
            .baseline_adjust => kCTFontBaselineAdjustAttribute,
            .macintosh_encodings => kCTFontMacintoshEncodingsAttribute,
            .features => kCTFontFeaturesAttribute,
            .feature_settings => kCTFontFeatureSettingsAttribute,
            .fixed_advance => kCTFontFixedAdvanceAttribute,
            .orientation => kCTFontOrientationAttribute,
            .format => kCTFontFormatAttribute,
            .registration_scope => kCTFontRegistrationScopeAttribute,
            .priority => kCTFontPriorityAttribute,
            .enabled => kCTFontEnabledAttribute,
            .downloadable => kCTFontDownloadableAttribute,
            .downloaded => kCTFontDownloadedAttribute,
        };
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

    extern "c" const kCTFontURLAttribute: *foundation.String;
    extern "c" const kCTFontNameAttribute: *foundation.String;
    extern "c" const kCTFontDisplayNameAttribute: *foundation.String;
    extern "c" const kCTFontFamilyNameAttribute: *foundation.String;
    extern "c" const kCTFontStyleNameAttribute: *foundation.String;
    extern "c" const kCTFontTraitsAttribute: *foundation.String;
    extern "c" const kCTFontVariationAttribute: *foundation.String;
    extern "c" const kCTFontVariationAxesAttribute: *foundation.String;
    extern "c" const kCTFontSizeAttribute: *foundation.String;
    extern "c" const kCTFontMatrixAttribute: *foundation.String;
    extern "c" const kCTFontCascadeListAttribute: *foundation.String;
    extern "c" const kCTFontCharacterSetAttribute: *foundation.String;
    extern "c" const kCTFontLanguagesAttribute: *foundation.String;
    extern "c" const kCTFontBaselineAdjustAttribute: *foundation.String;
    extern "c" const kCTFontMacintoshEncodingsAttribute: *foundation.String;
    extern "c" const kCTFontFeaturesAttribute: *foundation.String;
    extern "c" const kCTFontFeatureSettingsAttribute: *foundation.String;
    extern "c" const kCTFontFixedAdvanceAttribute: *foundation.String;
    extern "c" const kCTFontOrientationAttribute: *foundation.String;
    extern "c" const kCTFontFormatAttribute: *foundation.String;
    extern "c" const kCTFontRegistrationScopeAttribute: *foundation.String;
    extern "c" const kCTFontPriorityAttribute: *foundation.String;
    extern "c" const kCTFontEnabledAttribute: *foundation.String;
    extern "c" const kCTFontDownloadableAttribute: *foundation.String;
    extern "c" const kCTFontDownloadedAttribute: *foundation.String;
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
