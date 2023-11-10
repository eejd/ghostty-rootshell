/// Clipboard Confirmation Window
const ClipboardConfirmation = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const CoreSurface = @import("../../Surface.zig");
const ClipboardRequest = @import("../structs.zig").ClipboardRequest;
const ClipboardPromptReason = @import("../structs.zig").ClipboardPromptReason;
const App = @import("App.zig");
const View = @import("View.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

app: *App,
window: *c.GtkWindow,
view: PrimaryView,

data: [:0]u8,
core_surface: CoreSurface,
pending_req: ClipboardRequest,
reason: ClipboardPromptReason,

pub fn create(
    app: *App,
    data: []const u8,
    core_surface: CoreSurface,
    request: ClipboardRequest,
) !void {
    if (app.clipboard_confirmation_window != null) return error.WindowAlreadyExists;

    const alloc = app.core_app.alloc;
    const self = try alloc.create(ClipboardConfirmation);
    errdefer alloc.destroy(self);

    const reason: ClipboardPromptReason = switch (request) {
        .paste => .unsafe,
        .osc_52_read => .read,
        .osc_52_write => .write,
    };

    try self.init(
        app,
        data,
        core_surface,
        request,
        reason,
    );

    app.clipboard_confirmation_window = self;
}

/// Not public because this should be called by the GTK lifecycle.
fn destroy(self: *ClipboardConfirmation) void {
    const alloc = self.app.core_app.alloc;
    self.app.clipboard_confirmation_window = null;
    alloc.free(self.data);
    alloc.destroy(self);
}

fn init(
    self: *ClipboardConfirmation,
    app: *App,
    data: []const u8,
    core_surface: CoreSurface,
    request: ClipboardRequest,
    reason: ClipboardPromptReason,
) !void {
    // Create the window
    const window = c.gtk_window_new();
    const gtk_window: *c.GtkWindow = @ptrCast(window);
    errdefer c.gtk_window_destroy(gtk_window);
    c.gtk_window_set_title(gtk_window, titleText(reason));
    c.gtk_window_set_default_size(gtk_window, 550, 275);
    c.gtk_window_set_resizable(gtk_window, 0);
    _ = c.g_signal_connect_data(
        window,
        "destroy",
        c.G_CALLBACK(&gtkDestroy),
        self,
        null,
        c.G_CONNECT_DEFAULT,
    );

    // Set some state
    self.* = .{
        .app = app,
        .window = gtk_window,
        .view = undefined,
        .data = try app.core_app.alloc.dupeZ(u8, data),
        .core_surface = core_surface,
        .pending_req = request,
        .reason = reason,
    };

    // Show the window
    const view = try PrimaryView.init(self, data);
    self.view = view;
    c.gtk_window_set_child(@ptrCast(window), view.root);
    c.gtk_widget_show(window);

    // Block the main window from input.
    // This will auto-revert when the window is closed.
    c.gtk_window_set_modal(gtk_window, 1);
}

fn gtkDestroy(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud orelse return));
    self.destroy();
}

const PrimaryView = struct {
    root: *c.GtkWidget,
    text: *c.GtkTextView,

    pub fn init(root: *ClipboardConfirmation, data: []const u8) !PrimaryView {
        // All our widgets
        const label = c.gtk_label_new(promptText(root.reason));
        const buf = unsafeBuffer(data);
        defer c.g_object_unref(buf);
        const buttons = try ButtonsView.init(root);
        const text_scroll = c.gtk_scrolled_window_new();
        errdefer c.g_object_unref(text_scroll);
        const text = c.gtk_text_view_new_with_buffer(buf);
        errdefer c.g_object_unref(text);
        c.gtk_scrolled_window_set_child(@ptrCast(text_scroll), text);

        // Create our view
        const view = try View.init(&.{
            .{ .name = "label", .widget = label },
            .{ .name = "text", .widget = text_scroll },
            .{ .name = "buttons", .widget = buttons.root },
        }, &vfl);
        errdefer view.deinit();

        // We can do additional settings once the layout is setup
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_text_view_set_editable(@ptrCast(text), 0);
        c.gtk_text_view_set_cursor_visible(@ptrCast(text), 0);
        c.gtk_text_view_set_top_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_bottom_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_left_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_right_margin(@ptrCast(text), 8);

        return .{ .root = view.root, .text = @ptrCast(text) };
    }

    /// Returns the GtkTextBuffer for the data that was unsafe.
    fn unsafeBuffer(data: []const u8) *c.GtkTextBuffer {
        const buf = c.gtk_text_buffer_new(null);
        errdefer c.g_object_unref(buf);

        c.gtk_text_buffer_insert_at_cursor(buf, data.ptr, @intCast(data.len));

        return buf;
    }

    const vfl = [_][*:0]const u8{
        "H:|-8-[label]-8-|",
        "H:|[text]|",
        "H:|[buttons]|",
        "V:|[label(<=80)][text(>=100)]-[buttons]-|",
    };
};

const ButtonsView = struct {
    root: *c.GtkWidget,

    pub fn init(root: *ClipboardConfirmation) !ButtonsView {
        const cancel_text, const confirm_text = switch (root.reason) {
            .unsafe => .{ "Cancel", "Paste" },
            .read, .write => .{ "Deny", "Allow" },
            _ => unreachable,
        };

        const cancel_button = c.gtk_button_new_with_label(cancel_text);
        errdefer c.g_object_unref(cancel_button);

        const confirm_button = c.gtk_button_new_with_label(confirm_text);
        errdefer c.g_object_unref(confirm_button);

        // TODO: Focus on the paste button
        // c.gtk_widget_grab_focus(confirm_button);

        // Create our view
        const view = try View.init(&.{
            .{ .name = "cancel", .widget = cancel_button },
            .{ .name = "confirm", .widget = confirm_button },
        }, &vfl);

        // Signals
        _ = c.g_signal_connect_data(
            cancel_button,
            "clicked",
            c.G_CALLBACK(&gtkCancelClick),
            root,
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            confirm_button,
            "clicked",
            c.G_CALLBACK(&gtkConfirmClick),
            root,
            null,
            c.G_CONNECT_DEFAULT,
        );

        return .{ .root = view.root };
    }

    fn gtkCancelClick(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud));
        c.gtk_window_destroy(@ptrCast(self.window));
    }

    fn gtkConfirmClick(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        // Requeue the paste with force.
        const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud));
        self.core_surface.completeClipboardRequest(
            self.pending_req,
            self.data,
            true,
        ) catch |err| {
            std.log.err("Failed to requeue clipboard request: {}", .{err});
        };

        c.gtk_window_destroy(@ptrCast(self.window));
    }

    const vfl = [_][*:0]const u8{
        "H:[cancel]-8-[confirm]-8-|",
    };
};

/// The title of the window, based on the reason the prompt is being shown.
fn titleText(reason: ClipboardPromptReason) [:0]const u8 {
    return switch (reason) {
        .unsafe => "Warning: Potentially Unsafe Paste",
        .read, .write => "Authorize Clipboard Access",
        _ => unreachable,
    };
}

/// The text to display in the prompt window, based on the reason the prompt
/// is being shown.
fn promptText(reason: ClipboardPromptReason) [:0]const u8 {
    return switch (reason) {
        .unsafe =>
        \\Pasting this text into the terminal may be dangerous as it looks like some commands may be executed.
        ,
        .read =>
        \\An appliclication is attempting to read from the clipboard.
        \\The current clipboard contents are shown below.
        ,
        .write =>
        \\An application is attempting to write to the clipboard.
        \\The content to write is shown below.
        ,
        _ => unreachable,
    };
}
