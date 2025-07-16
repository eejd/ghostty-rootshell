const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const GhosttyApplication = @import("application.zig").GhosttyApplication;

const log = std.log.scoped(.gtk_ghostty_window);

pub const GhosttyWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        _todo: u8 = 0,
        var offset: c_int = 0;
    };

    pub fn new(app: *GhosttyApplication) *Self {
        return gobject.ext.newInstance(Self, .{ .application = app });
    }

    fn init(win: *GhosttyWindow, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(win.as(gtk.Widget));
    }

    pub fn as(win: *Self, comptime T: type) *T {
        return gobject.ext.as(T, win);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.C) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
