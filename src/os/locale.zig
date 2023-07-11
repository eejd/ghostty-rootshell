const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const objc = @import("objc");

const log = std.log.scoped(.os);

/// Ensure that the locale is set.
pub fn ensureLocale() void {
    assert(builtin.link_libc);

    // On macOS, pre-populate the LANG env var with system preferences.
    // When launching the .app, LANG is not set so we must query it from the
    // OS. When launching from the CLI, LANG is usually set by the parent
    // process.
    if (comptime builtin.target.isDarwin()) {
        // Set the lang if it is not set or if its empty.
        const set_lang = if (std.os.getenv("LANG")) |lang|
            lang.len == 0
        else
            true;

        if (set_lang) {
            setLangFromCocoa();
        }
    }

    // If we have a locale set in the env, we verify it is valid. If it isn't
    // valid, then we set it to a default value of en_US.UTF-8. We don't touch
    // the existing LANG value in the env so that child processes can use it,
    // though.
    const locale: []const u8 = locale: {
        // If we don't have lang set, we use "" and let the default happen.
        const lang = std.os.getenv("LANG") orelse break :locale "";

        // If the locale is valid, we also use "" because LANG is already set.
        if (localeIsValid(lang)) break :locale "";

        log.info("LANG is not valid according to libc, will use en_US.UTF-8", .{});
        break :locale "en_US.UTF-8";
    };

    // Set the locale
    if (setlocale(LC_ALL, locale.ptr)) |v| {
        log.debug("setlocale result={s}", .{v});
    } else log.warn("setlocale failed, locale may be incorrect", .{});
}

/// Returns true if the given locale is valid according to libc. This value
/// can be `en_US` or `en_US.utf-8` style of formatting.
fn localeIsValid(locale: []const u8) bool {
    const v = newlocale(LC_ALL_MASK, locale.ptr, null) orelse return false;
    defer freelocale(v);
    return true;
}

/// This sets the LANG environment variable based on the macOS system
/// preferences selected locale settings.
fn setLangFromCocoa() void {
    // Unknown Zig bug where in debug mode we can't pull the cocoa
    // value without crashing so we just force it to en_US.UTF-8.
    // Debug mode is only used for testing so to avoid this, devs can
    // just set LANG manually!
    if (builtin.mode == .Debug) {
        log.warn("in debug mode, we always set LANG to en_US.UTF-8 if not set", .{});
        if (setenv("LANG", "en_US.UTF-8", 1) < 0) {
            log.err("error setting locale env var", .{});
            return;
        }

        return;
    }

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
const LC_ALL_MASK: c_int = 0x7fffffff; // from locale.h
const locale_t = ?*anyopaque;
extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;
extern "c" fn setlocale(category: c_int, locale: ?[*]const u8) ?[*:0]u8;
extern "c" fn newlocale(category: c_int, locale: ?[*]const u8, base: locale_t) locale_t;
extern "c" fn freelocale(v: locale_t) void;
