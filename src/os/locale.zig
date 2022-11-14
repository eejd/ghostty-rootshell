const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const objc = @import("objc");

const log = std.log.scoped(.os);

/// Ensure that the locale is set.
pub fn ensureLocale() void {
    // On macOS, pre-populate the LANG env var with system preferences.
    // When launching the .app, LANG is not set so we must query it from the
    // OS. When launching from the CLI, LANG is usually set by the parent
    // process.
    if (comptime builtin.target.isDarwin()) {
        assert(builtin.link_libc);
        if (std.os.getenv("LANG") == null) {
            setLangFromCocoa();
        }
    }

    // Set the locale
    if (setlocale(LC_ALL, "")) |locale| {
        log.debug("setlocale result={s}", .{locale});
    } else log.warn("setlocale failed, locale may be incorrect", .{});
}

fn setLangFromCocoa() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // The classes we're going to need.
    const NSLocale = objc.Class.getClass("NSLocale") orelse {
        log.err("NSLocale class not found. Locale may be incorrect.", .{});
        return;
    };

    // Get our current locale and extract the language code ("en") and
    // country code ("US")
    const locale = NSLocale.msgSend(objc.Object, objc.sel("currentLocale"), .{});
    const lang = locale.getProperty(objc.Object, "languageCode");
    const country = locale.getProperty(objc.Object, "countryCode");

    // Get our UTF8 string values
    const c_lang = lang.getProperty([*:0]const u8, "UTF8String");
    const c_country = country.getProperty([*:0]const u8, "UTF8String");

    // Convert them to Zig slices
    const z_lang = std.mem.sliceTo(c_lang, 0);
    const z_country = std.mem.sliceTo(c_country, 0);

    // Format them into a buffer
    var buf: [128]u8 = undefined;
    const env_value = std.fmt.bufPrintZ(&buf, "{s}_{s}.UTF-8", .{ z_lang, z_country }) catch |err| {
        log.err("error setting locale from system. err={}", .{err});
        return;
    };
    log.info("detected system locale={s}", .{env_value});

    // Set it onto our environment
    if (setenv("LANG", env_value.ptr, 1) < 0) {
        log.err("error setting locale env var", .{});
        return;
    }
}

const LC_ALL: c_int = 6; // from locale.h
extern "c" fn setlocale(category: c_int, locale: ?[*]const u8) ?[*:0]u8;
extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;
