const std = @import("std");
const c = @import("c.zig").c;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const build_options = @import("build_options");

const log = std.log.scoped(.gtk_wayland);

/// Wayland state that contains application-wide Wayland objects (e.g. wl_display).
pub const AppState = struct {
    display: *wl.Display,

    pub fn init(display: ?*c.GdkDisplay) ?AppState {
        if (comptime !build_options.wayland) return null;

        // It should really never be null
        const display_ = display orelse return null;

        // Check if we're actually on Wayland
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(display_)),
            c.gdk_wayland_display_get_type(),
        ) == 0)
            return null;

        const wl_display: *wl.Display = @ptrCast(c.gdk_wayland_display_get_wl_display(display_) orelse return null);

        return .{
            .display = wl_display,
        };
    }

    pub fn register(self: *AppState) !void {
        const registry = try self.display.getRegistry();

        registry.setListener(*AppState, registryListener, self);
        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        log.debug("app wayland init={}", .{self});
    }
};

/// Wayland state that contains Wayland objects associated with a window (e.g. wl_surface).
pub const SurfaceState = struct {
    app_state: *AppState,
    surface: *wl.Surface,

    pub fn init(window: *c.GtkWindow, app_state: *AppState) ?SurfaceState {
        if (comptime !build_options.wayland) return null;

        const surface = c.gtk_native_get_surface(@ptrCast(window)) orelse return null;

        // Check if we're actually on Wayland
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(surface)),
            c.gdk_wayland_surface_get_type(),
        ) == 0)
            return null;

        const wl_surface: *wl.Surface = @ptrCast(c.gdk_wayland_surface_get_wl_surface(surface) orelse return null);

        return .{
            .app_state = app_state,
            .surface = wl_surface,
        };
    }

    pub fn deinit(self: *SurfaceState) void {
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *AppState) void {
    switch (event) {
        .global => |global| {
            log.debug("got global interface={s}", .{global.interface});
        },
        .global_remove => {},
    }
}

fn bindInterface(comptime T: type, registry: *wl.Registry, global: anytype, version: u32) ?*T {
    if (std.mem.orderZ(u8, global.interface, T.interface.name) == .eq) {
        return registry.bind(global.name, T, version) catch |err| {
            log.warn("encountered error={} while binding interface {s}", .{ err, global.interface });
            return null;
        };
    } else {
        return null;
    }
}
