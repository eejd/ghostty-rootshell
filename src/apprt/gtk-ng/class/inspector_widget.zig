const std = @import("std");

const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Inspector = @import("../../../inspector/Inspector.zig");

const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Surface = @import("surface.zig").Surface;
const ImguiWidget = @import("imgui_widget.zig").ImguiWidget;

const log = std.log.scoped(.gtk_ghostty_inspector_widget);

/// Widget for displaying the Ghostty inspector.
pub const InspectorWidget = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyInspectorWidget",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(Self, ?*Surface, .{
                        .getter = getSurface,
                        .getter_transfer = .full,
                        .setter = setSurface,
                        .setter_transfer = .none,
                    }),
                },
            );
        };
    };

    pub const signals = struct {};

    const Private = struct {
        /// The surface that we are attached to
        surface: WeakRef(Surface) = .empty,

        /// The embedded Dear ImGui widget.
        imgui_widget: *ImguiWidget,

        pub var offset: c_int = 0;
    };

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        deactivate: {
            const surface = priv.surface.get() orelse break :deactivate;
            defer surface.unref();

            const core_surface = surface.core() orelse break :deactivate;
            core_surface.deactivateInspector();
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Public methods

    pub fn new(surface: *Surface) *Self {
        return gobject.ext.newInstance(Self, .{
            .surface = surface,
        });
    }

    /// Queue a render of the Dear ImGui widget.
    pub fn queueRender(self: *Self) void {
        const priv = self.private();
        priv.imgui_widget.queueRender();
    }

    //---------------------------------------------------------------
    //  Private Methods

    //---------------------------------------------------------------
    // Properties

    fn getSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return priv.surface.get();
    }

    fn setSurface(self: *Self, newvalue_: ?*Surface) void {
        const priv = self.private();

        if (priv.surface.get()) |oldvalue| oldvalue: {
            defer oldvalue.unref();

            // We don't need to do anything if we're just setting the same surface.
            if (newvalue_) |newvalue| if (newvalue == oldvalue) return;

            // Deactivate the inspector on the old surface.
            const core_surface = oldvalue.core() orelse break :oldvalue;
            core_surface.deactivateInspector();
        }

        const newvalue = newvalue_ orelse {
            priv.surface.set(null);
            return;
        };

        const core_surface = newvalue.core() orelse {
            priv.surface.set(null);
            return;
        };

        // Activate the inspector on the new surface.
        core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        priv.surface.set(newvalue);

        self.queueRender();
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn imguiRender(
        _: *ImguiWidget,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const surface = priv.surface.get() orelse return;
        defer surface.unref();
        const core_surface = surface.core() orelse return;
        const inspector = core_surface.inspector orelse return;
        inspector.render();
    }

    fn imguiSetup(
        _: *ImguiWidget,
        _: *Self,
    ) callconv(.c) void {
        Inspector.setup();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(ImguiWidget);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "inspector-widget",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("imgui_widget", .{});

            // Template callbacks
            class.bindTemplateCallback("imgui_render", &imguiRender);
            class.bindTemplateCallback("imgui_setup", &imguiSetup);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.surface.impl,
            });

            // Signals

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
