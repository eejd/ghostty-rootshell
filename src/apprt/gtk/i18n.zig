//! I18n support for the GTK frontend based on gettext/libintl
//!
//! This is normally built into the C standard library for the *vast* majority
//! of users who use glibc, but for musl users we fall back to the `gettext-tiny`
//! stub implementation which provides all of the necessary interfaces.
//! Musl users who do want to use localization should know what they need to do.

const std = @import("std");
const global = &@import("../../global.zig").state;
const build_config = @import("../../build_config.zig");

const log = std.log.scoped(.gtk_i18n);

pub fn init(alloc: std.mem.Allocator) !void {
    const resources_dir = global.resources_dir orelse {
        log.warn("resource dir not found; not localizing", .{});
        return;
    };
    const share_dir = std.fs.path.dirname(resources_dir) orelse {
        log.warn("resource dir not placed in a share/ directory; not localizing", .{});
        return;
    };

    const locale_dir = try std.fs.path.joinZ(alloc, &.{ share_dir, "locale" });
    defer alloc.free(locale_dir);

    // The only way these calls can fail is if we're out of memory
    _ = bindtextdomain(build_config.bundle_id, locale_dir.ptr) orelse return error.OutOfMemory;
    _ = textdomain(build_config.bundle_id) orelse return error.OutOfMemory;
}

// Manually include function definitions for the gettext functions
// as libintl.h isn't always easily available (e.g. in musl)
extern fn bindtextdomain(domainname: [*:0]const u8, dirname: [*:0]const u8) ?[*:0]const u8;
extern fn textdomain(domainname: [*:0]const u8) ?[*:0]const u8;
pub extern fn gettext(msgid: [*:0]const u8) [*:0]const u8;
pub const _ = gettext;
