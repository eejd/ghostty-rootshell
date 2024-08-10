const ResizeOverlay = @This();

const std = @import("std");
const c = @import("c.zig");
const configpkg = @import("../../config.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.gtk);

/// Back reference to the surface we belong to
surface: ?*Surface = null,

/// If non-null this is the widget on the overlay that shows the size of the
/// surface when it is resized.
widget: ?*c.GtkWidget = null,

/// If non-null this is a timer for dismissing the resize overlay.
timer: ?c.guint = null,

/// If non-null this is a timer for dismissing the resize overlay.
idler: ?c.guint = null,

/// If true, the next resize event will be the first one.
first: bool = true,

/// If we're configured to do so, create a label widget for displaying the size
/// of the surface during a resize event.
pub fn init(
    surface: *Surface,
    config: *configpkg.Config,
    overlay: *c.GtkOverlay,
) ResizeOverlay {
    // At this point the surface object has been _created_ but not
    // _initialized_ so we can't use any information from it.

    if (config.@"resize-overlay" == .never) return .{};

    // Create the label that will show the resize information.
    const widget = c.gtk_label_new("");
    c.gtk_widget_add_css_class(widget, "view");
    c.gtk_widget_add_css_class(widget, "size-overlay");
    c.gtk_widget_add_css_class(widget, "hidden");
    c.gtk_widget_set_visible(widget, c.FALSE);
    c.gtk_widget_set_focusable(widget, c.FALSE);
    c.gtk_widget_set_can_target(widget, c.FALSE);
    c.gtk_label_set_justify(@ptrCast(widget), c.GTK_JUSTIFY_CENTER);
    c.gtk_label_set_selectable(@ptrCast(widget), c.FALSE);
    setOverlayWidgetPosition(widget, config);
    c.gtk_overlay_add_overlay(overlay, widget);

    return .{ .surface = surface, .widget = widget };
}

pub fn deinit(self: *ResizeOverlay) void {
    if (self.idler) |idler| {
        if (c.g_source_remove(idler) == c.FALSE) {
            log.warn("unable to remove resize overlay idler", .{});
        }
        self.idler = null;
    }

    if (self.timer) |timer| {
        if (c.g_source_remove(timer) == c.FALSE) {
            log.warn("unable to remove resize overlay timer", .{});
        }
        self.timer = null;
    }
}

/// If we're configured to do so, update the text in the resize overlay widget
/// and make it visible. Schedule a timer to hide the widget after the delay
/// expires.
///
/// If we're not configured to show the overlay, do nothing.
pub fn maybeShowResizeOverlay(self: *ResizeOverlay) void {
    if (self.widget == null) return;
    const surface = self.surface orelse return;

    switch (surface.app.config.@"resize-overlay") {
        .never => return,
        .always => {},
        .@"after-first" => if (self.first) {
            self.first = false;
            return;
        },
    }

    self.first = false;

    // When updating a widget, do so from GTK's thread, but not if there's
    // already an update queued up. Even though all our function calls ARE
    // from the main thread, we have to do this to avoid GTK warnings. My
    // guess is updating a widget in the hierarchy while another widget is
    // being resized is a bad idea.
    if (self.idler != null) return;
    self.idler = c.g_idle_add(gtkUpdateOverlayWidget, @ptrCast(self));
}

/// Actually update the overlay widget. This should only be called as an idle
/// handler.
fn gtkUpdateOverlayWidget(ud: ?*anyopaque) callconv(.C) c.gboolean {
    const self: *ResizeOverlay = @ptrCast(@alignCast(ud));

    // No matter what our idler is complete with this callback
    self.idler = null;

    const widget = self.widget orelse return c.FALSE;
    const surface = self.surface orelse return c.FALSE;

    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrintZ(
        &buf,
        "{d}c ⨯ {d}r",
        .{
            surface.core_surface.grid_size.columns,
            surface.core_surface.grid_size.rows,
        },
    ) catch |err| {
        log.err("unable to format text: {}", .{err});
        return c.FALSE;
    };

    c.gtk_label_set_text(@ptrCast(widget), text.ptr);
    c.gtk_widget_remove_css_class(@ptrCast(widget), "hidden");
    c.gtk_widget_set_visible(@ptrCast(widget), 1);

    setOverlayWidgetPosition(widget, &surface.app.config);

    if (self.timer) |timer| {
        if (c.g_source_remove(timer) == c.FALSE) {
            log.warn("unable to remove size overlay timer", .{});
        }
    }
    self.timer = c.g_timeout_add(
        surface.app.config.@"resize-overlay-duration".asMilliseconds(),
        gtkResizeOverlayTimerExpired,
        @ptrCast(self),
    );

    return c.FALSE;
}

/// Update the position of the resize overlay widget. It might seem excessive to
/// do this often, but it should make hot config reloading of the position work.
fn setOverlayWidgetPosition(widget: *c.GtkWidget, config: *configpkg.Config) void {
    c.gtk_widget_set_halign(
        @ptrCast(widget),
        switch (config.@"resize-overlay-position") {
            .center, .@"top-center", .@"bottom-center" => c.GTK_ALIGN_CENTER,
            .@"top-left", .@"bottom-left" => c.GTK_ALIGN_START,
            .@"top-right", .@"bottom-right" => c.GTK_ALIGN_END,
        },
    );
    c.gtk_widget_set_valign(
        @ptrCast(widget),
        switch (config.@"resize-overlay-position") {
            .center => c.GTK_ALIGN_CENTER,
            .@"top-left", .@"top-center", .@"top-right" => c.GTK_ALIGN_START,
            .@"bottom-left", .@"bottom-center", .@"bottom-right" => c.GTK_ALIGN_END,
        },
    );
}

/// If this fires, it means that the delay period has expired and the resize
/// overlay widget should be hidden.
fn gtkResizeOverlayTimerExpired(ud: ?*anyopaque) callconv(.C) c.gboolean {
    const self: *ResizeOverlay = @ptrCast(@alignCast(ud));
    self.timer = null;
    if (self.widget) |widget| {
        c.gtk_widget_add_css_class(@ptrCast(widget), "hidden");
        c.gtk_widget_set_visible(@ptrCast(widget), c.FALSE);
    }
    return c.FALSE;
}
