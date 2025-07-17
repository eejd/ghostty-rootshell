const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const adw_version = @import("../adw_version.zig");
const Config = @import("config.zig").GhosttyConfig;

const log = std.log.scoped(.gtk_ghostty_window);

pub const ConfigErrorsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,

    pub const Parent = if (adw_version.supportsDialogs())
        adw.AlertDialog
    else
        adw.MessageDialog;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyConfigErrorsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = gobject.ext.defineProperty(
            "config",
            Self,
            ?*Config,
            .{
                .nick = "config",
                .blurb = "The configuration that this dialog is showing errors for.",
                .default = null,
                .accessor = gobject.ext.privateFieldAccessor(
                    Self,
                    Private,
                    &Private.offset,
                    "config",
                ),
            },
        );
    };

    const Private = struct {
        config: ?*Config,
        var offset: c_int = 0;
    };

    pub fn new(config: *Config) *Self {
        return gobject.ext.newInstance(Self, .{
            .config = config,
        });
    }

    fn init(self: *Self, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        switch (Parent) {
            adw.AlertDialog => self.as(adw.Dialog).present(parent),
            else => unreachable,
        }
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
                switch (Parent) {
                    adw.AlertDialog => comptime gresource.blueprint(.{
                        .major = 1,
                        .minor = 5,
                        .name = "config-errors-dialog",
                    }),

                    else => unreachable,
                },
            );

            gobject.ext.registerProperties(class, &.{
                properties.config,
            });
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
