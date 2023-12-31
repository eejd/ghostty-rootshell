/// Utility functions for X11 handling.
const std = @import("std");
const c = @import("c.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.gtk_x11);

/// Returns true if the passed in display is an X11 display.
pub fn x11_is_display(display: ?*c.GdkDisplay) bool {
    return c.g_type_check_instance_is_a(
        @ptrCast(@alignCast(display orelse return false)),
        c.gdk_x11_display_get_type(),
    ) != 0;
}

pub const X11Xkb = struct {
    opcode: c_int,
    base_event_code: c_int,
    base_error_code: c_int,
    funcs: Funcs,

    /// Initialize an X11Xkb struct, for the given GDK display. If the display
    /// isn't backed by X then this will return null.
    pub fn init(display_: ?*c.GdkDisplay) !?X11Xkb {
        // Display should never be null but we just treat that as a non-X11
        // display so that the caller can just ignore it and not unwrap it.
        const display = display_ orelse return null;

        // If the display isn't X11, then we don't need to do anything.
        if (!x11_is_display(display)) return null;

        log.debug("X11Xkb.init: initializing Xkb", .{});
        const xdisplay = c.gdk_x11_display_get_xdisplay(display);
        var result: X11Xkb = .{
            .opcode = 0,
            .base_event_code = 0,
            .base_error_code = 0,
            .funcs = try Funcs.init(),
        };

        log.debug("X11Xkb.init: running XkbQueryExtension", .{});
        var major = c.XkbMajorVersion;
        var minor = c.XkbMinorVersion;
        if (result.funcs.XkbQueryExtension(
            xdisplay,
            &result.opcode,
            &result.base_event_code,
            &result.base_error_code,
            &major,
            &minor,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbQueryExtension", .{});
            return error.XkbInitializationError;
        }

        log.debug("X11Xkb.init: running XkbSelectEventDetails", .{});
        if (result.funcs.XkbSelectEventDetails(
            xdisplay,
            c.XkbUseCoreKbd,
            c.XkbStateNotify,
            c.XkbModifierStateMask,
            c.XkbModifierStateMask,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbSelectEventDetails", .{});
            return error.XkbInitializationError;
        }

        return result;
    }

    /// Checks for an immediate pending XKB state update event, and returns the
    /// keyboard state based on if it finds any. This is necessary as the
    /// standard GTK X11 API (and X11 in general) does not include the current
    /// key pressed in any modifier state snapshot for that event (e.g. if the
    /// pressed key is a modifier, that is not necessarily reflected in the
    /// modifiers).
    ///
    /// Returns null if there is no event. In this case, the caller should fall
    /// back to the standard GDK modifier state (this likely means the key
    /// event did not result in a modifier change).
    pub fn modifier_state_from_notify(self: X11Xkb, display_: ?*c.GdkDisplay) ?input.Mods {
        const display = display_ orelse return null;

        // Shoutout to Mozilla for figuring out a clean way to do this, this is
        // paraphrased from Firefox/Gecko in widget/gtk/nsGtkKeyUtils.cpp.
        const xdisplay = c.gdk_x11_display_get_xdisplay(display);
        if (self.funcs.XEventsQueued(xdisplay, c.QueuedAfterReading) == 0) return null;

        var nextEvent: c.XEvent = undefined;
        _ = self.funcs.XPeekEvent(xdisplay, &nextEvent);
        if (nextEvent.type != self.base_event_code) return null;

        const xkb_event: *c.XkbEvent = @ptrCast(&nextEvent);
        if (xkb_event.any.xkb_type != c.XkbStateNotify) return null;

        const xkb_state_notify_event: *c.XkbStateNotifyEvent = @ptrCast(xkb_event);
        // Check the state according to XKB masks.
        const lookup_mods = xkb_state_notify_event.lookup_mods;
        var mods: input.Mods = .{};

        log.debug("X11: found extra XkbStateNotify event w/lookup_mods: {b}", .{lookup_mods});
        if (lookup_mods & c.ShiftMask != 0) mods.shift = true;
        if (lookup_mods & c.ControlMask != 0) mods.ctrl = true;
        if (lookup_mods & c.Mod1Mask != 0) mods.alt = true;
        if (lookup_mods & c.Mod2Mask != 0) mods.super = true;
        if (lookup_mods & c.LockMask != 0) mods.caps_lock = true;

        return mods;
    }
};

/// The functions that we load dynamically from libX11.so.
const Funcs = struct {
    XkbQueryExtension: XkbQueryExtensionType,
    XkbSelectEventDetails: XkbSelectEventDetailsType,
    XEventsQueued: XEventsQueuedType,
    XPeekEvent: XPeekEventType,

    // X11 Function types. We load these dynamically at runtime to avoid having to
    // link against X11.
    const XkbQueryExtensionType = *const fn (?*c.struct__XDisplay, [*c]c_int, [*c]c_int, [*c]c_int, [*c]c_int, [*c]c_int) callconv(.C) c_int;
    const XkbSelectEventDetailsType = *const fn (?*c.struct__XDisplay, c_uint, c_uint, c_ulong, c_ulong) callconv(.C) c_int;
    const XEventsQueuedType = *const fn (?*c.struct__XDisplay, c_int) callconv(.C) c_int;
    const XPeekEventType = *const fn (?*c.struct__XDisplay, [*c]c.union__XEvent) callconv(.C) c_int;

    pub fn init() !Funcs {
        var libX11 = try std.DynLib.open("libX11.so");
        defer libX11.close();

        var result: Funcs = undefined;
        inline for (@typeInfo(Funcs).Struct.fields) |field| {
            const name = comptime name: {
                const null_term = field.name ++ .{0};
                break :name null_term[0..field.name.len :0];
            };

            @field(result, field.name) = libX11.lookup(
                field.type,
                name,
            ) orelse {
                log.err(" error dynamic loading libX11: missing symbol {s}", .{field.name});
                return error.XkbInitializationError;
            };
        }

        return result;
    }
};
