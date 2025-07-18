const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const internal_os = @import("../../../os/main.zig");
const renderer = @import("../../../renderer.zig");
const CoreSurface = @import("../../../Surface.zig");
const gresource = @import("../build/gresource.zig");
const adw_version = @import("../adw_version.zig");
const ApprtSurface = @import("../Surface.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_surface);

pub const Surface = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySurface",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .nick = "Config",
                    .blurb = "The configuration that this surface is using.",
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
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// The GLAarea that renders the actual surface. This is a binding
        /// to the template so it doesn't have to be unrefed manually.
        gl_area: *gtk.GLArea,

        /// The apprt Surface.
        rt_surface: ApprtSurface,

        /// The core surface backing this GTK surface. This starts out
        /// null because it can't be initialized until there is an available
        /// GLArea that is realized.
        //
        // NOTE(mitchellh): This is a limitation we should definitely remove
        // at some point by modifying our OpenGL renderer for GTK to
        // start in an unrealized state. There are other benefits to being
        // able to initialize the surface early so we should aim for that,
        // eventually.
        core_surface: ?*CoreSurface = null,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn core(self: *Self) ?*CoreSurface {
        const priv = self.private();
        return priv.core_surface;
    }

    pub fn rt(self: *Self) *ApprtSurface {
        const priv = self.private();
        return &priv.rt_surface;
    }

    /// Force the surface to redraw itself. Ghostty often will only redraw
    /// the terminal in reaction to internal changes. If there are external
    /// events that invalidate the surface, such as the widget moving parents,
    /// then we should force a redraw.
    fn redraw(self: *Self) void {
        const priv = self.private();
        priv.gl_area.queueRender();
    }

    //---------------------------------------------------------------
    // Libghostty Callbacks

    pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
        _ = self;

        const alloc = Application.default().allocator();
        var env = try internal_os.getEnvMap(alloc);
        errdefer env.deinit();

        // Don't leak these GTK environment variables to child processes.
        env.remove("GDK_DEBUG");
        env.remove("GDK_DISABLE");
        env.remove("GSK_RENDERER");

        // Remove some environment variables that are set when Ghostty is launched
        // from a `.desktop` file, by D-Bus activation, or systemd.
        env.remove("GIO_LAUNCHED_DESKTOP_FILE");
        env.remove("GIO_LAUNCHED_DESKTOP_FILE_PID");
        env.remove("DBUS_STARTER_ADDRESS");
        env.remove("DBUS_STARTER_BUS_TYPE");
        env.remove("INVOCATION_ID");
        env.remove("JOURNAL_STREAM");
        env.remove("NOTIFY_SOCKET");

        // Unset environment varies set by snaps if we're running in a snap.
        // This allows Ghostty to further launch additional snaps.
        if (env.get("SNAP")) |_| {
            env.remove("SNAP");
            env.remove("DRIRC_CONFIGDIR");
            env.remove("__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS");
            env.remove("__EGL_VENDOR_LIBRARY_DIRS");
            env.remove("LD_LIBRARY_PATH");
            env.remove("LIBGL_DRIVERS_PATH");
            env.remove("LIBVA_DRIVERS_PATH");
            env.remove("VK_LAYER_PATH");
            env.remove("XLOCALEDIR");
            env.remove("GDK_PIXBUF_MODULEDIR");
            env.remove("GDK_PIXBUF_MODULE_FILE");
            env.remove("GTK_PATH");
        }

        return env;
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();

        // Initialize our apprt surface.
        priv.rt_surface = .{ .surface = self };

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        // Initialize our GLArea. We could do a lot of this in
        // the Blueprint file but I think its cleaner to separate
        // the "UI" part of the blueprint file from the internal logic/config
        // part.
        const gl_area = priv.gl_area;
        gl_area.setRequiredVersion(
            renderer.OpenGL.MIN_VERSION_MAJOR,
            renderer.OpenGL.MIN_VERSION_MINOR,
        );
        gl_area.setHasStencilBuffer(0);
        gl_area.setHasDepthBuffer(0);
        gl_area.setUseEs(0);
        _ = gtk.Widget.signals.realize.connect(
            gl_area,
            *Self,
            glareaRealize,
            self,
            .{},
        );
        _ = gtk.Widget.signals.unrealize.connect(
            gl_area,
            *Self,
            glareaUnrealize,
            self,
            .{},
        );
    }

    fn dispose(self: *Self) callconv(.C) void {
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
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

    fn finalize(self: *Self) callconv(.C) void {
        const priv = self.private();
        if (priv.core_surface) |v| {
            priv.core_surface = null;

            // Remove ourselves from the list of known surfaces in the app.
            // We do this before deinit in case a callback triggers
            // searching for this surface.
            Application.default().core().deleteSurface(self.rt());

            // Deinit the surface
            v.deinit();
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn glareaRealize(
        _: *gtk.GLArea,
        self: *Self,
    ) callconv(.c) void {
        log.debug("realize", .{});

        self.realizeSurface() catch |err| {
            log.warn("surface failed to realize err={}", .{err});
            return;
        };
    }

    fn glareaUnrealize(
        gl_area: *gtk.GLArea,
        self: *Self,
    ) callconv(.c) void {
        log.debug("unrealize", .{});

        // Get our surface. If we don't have one, there's no work we
        // need to do here.
        const priv = self.private();
        const surface = priv.core_surface orelse return;

        // There is no guarantee that our GLArea context is current
        // when unrealize is emitted, so we need to make it current.
        gl_area.makeCurrent();
        if (gl_area.getError()) |err| {
            // I don't know a scenario this can happen, but it means
            // we probably leaked memory because displayUnrealized
            // below frees resources that aren't specifically OpenGL
            // related. I didn't make the OpenGL renderer handle this
            // scenario because I don't know if its even possible
            // under valid circumstances, so let's log.
            log.warn(
                "gl_area_make_current failed in unrealize msg={s}",
                .{err.f_message orelse "(no message)"},
            );
            log.warn("OpenGL resources and memory likely leaked", .{});
            return;
        }

        surface.renderer.displayUnrealized();
    }

    const RealizeError = Allocator.Error || error{
        GLAreaError,
        RendererError,
        SurfaceError,
    };

    fn realizeSurface(self: *Self) RealizeError!void {
        const priv = self.private();
        const gl_area = priv.gl_area;

        // We need to make the context current so we can call GL functions.
        // This is required for all surface operations.
        gl_area.makeCurrent();
        if (gl_area.getError()) |err| {
            log.warn("failed to make GL context current: {s}", .{err.f_message orelse "(no message)"});
            log.warn("this error is usually due to a driver or gtk bug", .{});
            log.warn("this is a common cause of this issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/4950", .{});
            return error.GLAreaError;
        }

        // If we already have an initialized surface then we just notify.
        if (priv.core_surface) |v| {
            v.renderer.displayRealized() catch |err| {
                log.warn("core displayRealized failed err={}", .{err});
                return error.RendererError;
            };
            self.redraw();
            return;
        }

        // Make our pointer to store our surface
        const app = Application.default();
        const alloc = app.allocator();
        const surface = try alloc.create(CoreSurface);
        errdefer alloc.destroy(surface);

        // Add ourselves to the list of surfaces on the app.
        try app.core().addSurface(self.rt());
        errdefer app.core().deleteSurface(self.rt());

        // Initialize our surface configuration.
        var config = try apprt.surface.newConfig(
            app.core(),
            priv.config.?.get(),
        );
        defer config.deinit();

        // Initialize the surface
        surface.init(
            alloc,
            &config,
            app.core(),
            app.rt(),
            &priv.rt_surface,
        ) catch |err| {
            log.warn("failed to initialize surface err={}", .{err});
            return error.SurfaceError;
        };
        errdefer surface.deinit();

        // Store it!
        priv.core_surface = surface;
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.C) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "surface",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("gl_area", .{});

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
