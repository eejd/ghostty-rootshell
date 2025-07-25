const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

/// Debug warning banner. It will be based on adw.Banner if we're using Adwaita
/// 1.3 or newer. Otherwise it will use a gtk.Label.
pub const DebugWarning = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = if (adw_version.supportsBanner()) adw.Bin else gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyDebugWarning",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub const properties = struct {
        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .nick = "Debug",
                    .blurb = "True if runtime safety checks are enabled.",
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *DebugWarning) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    const C = Common(Self, null);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = if (adw_version.supportsBanner()) 3 else 2,
                    .name = "debug-warning",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.debug.impl,
            });
        }

        pub const as = C.Class.as;
    };
};
