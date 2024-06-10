const std = @import("std");
const c = @import("c.zig").c;
const build_options = @import("build_options");

const Window = @import("./Window.zig");
const userdataSelf = Window.userdataSelf;
const Tab = @import("./Tab.zig");

const log = std.log.scoped(.gtk);

const AdwTabView = if (build_options.libadwaita) c.AdwTabView else anyopaque;

pub const Notebook = union(enum) {
    adw_tab_view: *AdwTabView,
    gtk_notebook: *c.GtkNotebook,

    pub fn create(window: *Window, box: *c.GtkWidget) @This() {
        const app = window.app;

        const adwaita = build_options.libadwaita and app.config.@"gtk-adwaita";

        if (adwaita) {
            log.warn("using adwaita", .{});
            const tab_view = c.adw_tab_view_new();
            const tab_bar = c.adw_tab_bar_new();
            c.gtk_box_append(@ptrCast(box), @ptrCast(@alignCast(tab_bar)));
            c.adw_tab_bar_set_view(tab_bar, tab_view);

            if (!window.app.config.@"gtk-wide-tabs")
                c.adw_tab_bar_set_expand_tabs(tab_bar, 0);

            _ = c.g_signal_connect_data(tab_view, "page-attached", c.G_CALLBACK(&adwPageAttached), window, null, c.G_CONNECT_DEFAULT);
            _ = c.g_signal_connect_data(tab_view, "create-window", c.G_CALLBACK(&adwTabViewCreateWindow), window, null, c.G_CONNECT_DEFAULT);

            return .{ .adw_tab_view = tab_view.? };
        }

        // Create a notebook to hold our tabs.
        const notebook_widget = c.gtk_notebook_new();
        const notebook: *c.GtkNotebook = @ptrCast(notebook_widget);
        const notebook_tab_pos: c_uint = switch (app.config.@"gtk-tabs-location") {
            .top => c.GTK_POS_TOP,
            .bottom => c.GTK_POS_BOTTOM,
            .left => c.GTK_POS_LEFT,
            .right => c.GTK_POS_RIGHT,
        };
        c.gtk_notebook_set_tab_pos(notebook, notebook_tab_pos);
        c.gtk_notebook_set_scrollable(notebook, 1);
        c.gtk_notebook_set_show_tabs(notebook, 0);
        c.gtk_notebook_set_show_border(notebook, 0);

        // This enables all Ghostty terminal tabs to be exchanged across windows.
        c.gtk_notebook_set_group_name(notebook, "ghostty-terminal-tabs");

        // This is important so the notebook expands to fit available space.
        // Otherwise, it will be zero/zero in the box below.
        c.gtk_widget_set_vexpand(notebook_widget, 1);
        c.gtk_widget_set_hexpand(notebook_widget, 1);

        // If we are in fullscreen mode, new windows start fullscreen.
        if (app.config.fullscreen) c.gtk_window_fullscreen(window.window);

        // All of our events
        _ = c.g_signal_connect_data(notebook, "page-added", c.G_CALLBACK(&gtkPageAdded), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(notebook, "page-removed", c.G_CALLBACK(&gtkPageRemoved), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(notebook, "switch-page", c.G_CALLBACK(&gtkSwitchPage), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(notebook, "create-window", c.G_CALLBACK(&gtkNotebookCreateWindow), window, null, c.G_CONNECT_DEFAULT);

        return .{ .gtk_notebook = notebook };
    }

    pub fn as_widget(self: Notebook) *c.GtkWidget {
        return switch (self) {
            .adw_tab_view => |ptr| @ptrCast(@alignCast(ptr)),
            .gtk_notebook => |ptr| @ptrCast(@alignCast(ptr)),
        };
    }

    pub fn nPages(self: Notebook) c_int {
        return switch (self) {
            .adw_tab_view => |tab_view| if (build_options.libadwaita) c.adw_tab_view_get_n_pages(tab_view) else unreachable,
            .gtk_notebook => |notebook| c.gtk_notebook_get_n_pages(notebook),
        };
    }

    pub fn currentPage(self: Notebook) c_int {
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (!build_options.libadwaita) unreachable;
                const page = c.adw_tab_view_get_selected_page(tab_view);
                return c.adw_tab_view_get_page_position(tab_view, page);
            },
            .gtk_notebook => |notebook| return c.gtk_notebook_get_current_page(notebook),
        }
    }

    pub fn currentTab(self: Notebook) ?*Tab {
        log.info("self = {}", .{self});
        const child = switch (self) {
            .adw_tab_view => |tab_view| child: {
                if (!build_options.libadwaita) unreachable;
                const page = c.adw_tab_view_get_selected_page(tab_view) orelse return null;
                const child = c.adw_tab_page_get_child(page);
                break :child child;
            },
            .gtk_notebook => |notebook| child: {
                const page = self.currentPage();
                if (page == -1) return null;
                log.info("currentPage_page_idx = {}", .{page});
                break :child c.gtk_notebook_get_nth_page(notebook, page);
            },
        };
        return @ptrCast(@alignCast(
            c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return null,
        ));
    }

    pub fn gotoNthTab(self: Notebook, position: c_int) void {
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (!build_options.libadwaita) unreachable;
                const page_to_select = c.adw_tab_view_get_nth_page(tab_view, position);
                c.adw_tab_view_set_selected_page(tab_view, page_to_select);
            },
            .gtk_notebook => |notebook| c.gtk_notebook_set_current_page(notebook, position),
        }
    }

    pub fn getTabPosition(self: Notebook, tab: *Tab) ?c_int {
        return switch (self) {
            .adw_tab_view => |tab_view| page_idx: {
                if (!build_options.libadwaita) unreachable;
                const page = c.adw_tab_view_get_page(tab_view, @ptrCast(tab.box)) orelse return null;
                break :page_idx c.adw_tab_view_get_page_position(tab_view, page);
            },
            .gtk_notebook => |notebook| page_idx: {
                const page = c.gtk_notebook_get_page(notebook, @ptrCast(tab.box)) orelse return null;
                break :page_idx getNotebookPageIndex(page);
            },
        };
    }

    pub fn gotoPreviousTab(self: Notebook, tab: *Tab) void {
        const page_idx = self.getTabPosition(tab) orelse return;

        // The next index is the previous or we wrap around.
        const next_idx = if (page_idx > 0) page_idx - 1 else next_idx: {
            const max = self.nPages();
            break :next_idx max -| 1;
        };

        // Do nothing if we have one tab
        if (next_idx == page_idx) return;

        self.gotoNthTab(next_idx);
    }

    pub fn gotoNextTab(self: Notebook, tab: *Tab) void {
        const page_idx = self.getTabPosition(tab) orelse return;

        const max = self.nPages() -| 1;
        const next_idx = if (page_idx < max) page_idx + 1 else 0;
        if (next_idx == page_idx) return;

        self.gotoNthTab(next_idx);
    }

    pub fn setTabLabel(self: Notebook, tab: *Tab, title: [:0]const u8) void {
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (!build_options.libadwaita) unreachable;
                const page = c.adw_tab_view_get_page(tab_view, @ptrCast(tab.box));
                c.adw_tab_page_set_title(page, title.ptr);
            },
            .gtk_notebook => c.gtk_label_set_text(tab.label_text, title.ptr),
        }
    }

    pub fn addTab(self: Notebook, tab: *Tab, title: [:0]const u8) !void {
        const box_widget: *c.GtkWidget = @ptrCast(tab.box);
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (!build_options.libadwaita) unreachable;

                const page = c.adw_tab_view_append(tab_view, box_widget);
                c.adw_tab_page_set_title(page, title.ptr);

                // Switch to the new tab
                c.adw_tab_view_set_selected_page(tab_view, page);
            },
            .gtk_notebook => |notebook| {
                // Build the tab label
                const label_box_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
                const label_box = @as(*c.GtkBox, @ptrCast(label_box_widget));
                const label_text_widget = c.gtk_label_new(title.ptr);
                const label_text: *c.GtkLabel = @ptrCast(label_text_widget);
                c.gtk_box_append(label_box, label_text_widget);
                tab.label_text = label_text;

                const window = tab.window;
                if (window.app.config.@"gtk-wide-tabs") {
                    c.gtk_widget_set_hexpand(label_box_widget, 1);
                    c.gtk_widget_set_halign(label_box_widget, c.GTK_ALIGN_FILL);
                    c.gtk_widget_set_hexpand(label_text_widget, 1);
                    c.gtk_widget_set_halign(label_text_widget, c.GTK_ALIGN_FILL);

                    // This ensures that tabs are always equal width. If they're too
                    // long, they'll be truncated with an ellipsis.
                    c.gtk_label_set_max_width_chars(label_text, 1);
                    c.gtk_label_set_ellipsize(label_text, c.PANGO_ELLIPSIZE_END);

                    // We need to set a minimum width so that at a certain point
                    // the notebook will have an arrow button rather than shrinking tabs
                    // to an unreadably small size.
                    c.gtk_widget_set_size_request(label_text_widget, 100, 1);
                }

                // Build the close button for the tab
                const label_close_widget = c.gtk_button_new_from_icon_name("window-close-symbolic");
                const label_close: *c.GtkButton = @ptrCast(label_close_widget);
                c.gtk_button_set_has_frame(label_close, 0);
                c.gtk_box_append(label_box, label_close_widget);

                const parent_page_idx = self.nPages();
                const page_idx = c.gtk_notebook_insert_page(
                    notebook,
                    box_widget,
                    label_box_widget,
                    parent_page_idx,
                );

                // Clicks
                const gesture_tab_click = c.gtk_gesture_click_new();
                c.gtk_gesture_single_set_button(@ptrCast(gesture_tab_click), 0);
                c.gtk_widget_add_controller(label_box_widget, @ptrCast(gesture_tab_click));

                _ = c.g_signal_connect_data(label_close, "clicked", c.G_CALLBACK(&Tab.gtkTabCloseClick), tab, null, c.G_CONNECT_DEFAULT);
                _ = c.g_signal_connect_data(gesture_tab_click, "pressed", c.G_CALLBACK(&Tab.gtkTabClick), tab, null, c.G_CONNECT_DEFAULT);

                if (self.nPages() > 1) {
                    c.gtk_notebook_set_show_tabs(notebook, 1);
                }

                // Switch to the new tab
                c.gtk_notebook_set_current_page(notebook, page_idx);
            },
        }
    }

    pub fn closeTab(self: Notebook, tab: *Tab) void {
        const window = tab.window;
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (!build_options.libadwaita) unreachable;

                const page = c.adw_tab_view_get_page(tab_view, @ptrCast(tab.box)) orelse return;
                c.adw_tab_view_close_page(tab_view, page);

                // If we have no more tabs we close the window
                if (self.nPages() == 0)
                    c.gtk_window_destroy(tab.window.window);
            },
            .gtk_notebook => |notebook| {
                const page = c.gtk_notebook_get_page(notebook, @ptrCast(tab.box)) orelse return;

                // Find page and tab which we're closing
                const page_idx = getNotebookPageIndex(page);

                // Remove the page. This will destroy the GTK widgets in the page which
                // will trigger Tab cleanup. The `tab` variable is therefore unusable past that point.
                c.gtk_notebook_remove_page(notebook, page_idx);

                const remaining = self.nPages();
                switch (remaining) {
                    // If we have no more tabs we close the window
                    0 => c.gtk_window_destroy(tab.window.window),

                    // If we have one more tab we hide the tab bar
                    1 => c.gtk_notebook_set_show_tabs(notebook, 0),

                    else => {},
                }

                // If we have remaining tabs, we need to make sure we grab focus.
                if (remaining > 0) window.focusCurrentTab();
            },
        }
    }

    pub fn getNotebookPageIndex(page: *c.GtkNotebookPage) c_int {
        var value: c.GValue = std.mem.zeroes(c.GValue);
        defer c.g_value_unset(&value);
        _ = c.g_value_init(&value, c.G_TYPE_INT);
        c.g_object_get_property(
            @ptrCast(@alignCast(page)),
            "position",
            &value,
        );

        return c.g_value_get_int(&value);
    }
};

fn gtkPageRemoved(
    _: *c.GtkNotebook,
    _: *c.GtkWidget,
    _: c.guint,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);

    const notebook: *c.GtkNotebook = self.notebook.gtk_notebook;

    // Hide the tab bar if we only have one tab after removal
    const remaining = c.gtk_notebook_get_n_pages(notebook);
    if (remaining == 1) {
        c.gtk_notebook_set_show_tabs(notebook, 0);
    }
}

fn adwPageAttached(tab_view: *AdwTabView, page: *c.AdwTabPage, position: c_int, ud: ?*anyopaque) callconv(.C) void {
    _ = position;
    _ = tab_view;
    const self = userdataSelf(ud.?);

    const child = c.adw_tab_page_get_child(page);
    const tab: *Tab = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return));
    tab.window = self;

    self.focusCurrentTab();
}

fn gtkPageAdded(
    notebook: *c.GtkNotebook,
    _: *c.GtkWidget,
    page_idx: c.guint,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);

    // The added page can come from another window with drag and drop, thus we migrate the tab
    // window to be self.
    const page = c.gtk_notebook_get_nth_page(notebook, @intCast(page_idx));
    const tab: *Tab = @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(page), Tab.GHOSTTY_TAB) orelse return,
    ));
    tab.window = self;

    // Whenever a new page is added, we always grab focus of the
    // currently selected page. This was added specifically so that when
    // we drag a tab out to create a new window ("create-window" event)
    // we grab focus in the new window. Without this, the terminal didn't
    // have focus.
    self.focusCurrentTab();
}

fn gtkSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: usize, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const gtk_label_box = @as(*c.GtkWidget, @ptrCast(c.gtk_notebook_get_tab_label(self.notebook.gtk_notebook, page)));
    const gtk_label = @as(*c.GtkLabel, @ptrCast(c.gtk_widget_get_first_child(gtk_label_box)));
    const label_text = c.gtk_label_get_text(gtk_label);
    c.gtk_window_set_title(self.window, label_text);
}

fn adwTabViewCreateWindow(
    _: *AdwTabView,
    ud: ?*anyopaque,
) callconv(.C) ?*AdwTabView {
    const currentWindow = userdataSelf(ud.?);
    const window = createWindow(currentWindow) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };
    return window.notebook.adw_tab_view;
}

fn gtkNotebookCreateWindow(
    _: *c.GtkNotebook,
    page: *c.GtkWidget,
    ud: ?*anyopaque,
) callconv(.C) ?*c.GtkNotebook {
    // The tab for the page is stored in the widget data.
    const tab: *Tab = @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(page), Tab.GHOSTTY_TAB) orelse return null,
    ));

    const currentWindow = userdataSelf(ud.?);
    const window = createWindow(currentWindow) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };

    // And add it to the new window.
    tab.window = window;

    return window.notebook.gtk_notebook;
}

fn createWindow(currentWindow: *Window) !*Window {
    const alloc = currentWindow.app.core_app.alloc;
    const app = currentWindow.app;

    // Create a new window
    return Window.create(alloc, app);
}
