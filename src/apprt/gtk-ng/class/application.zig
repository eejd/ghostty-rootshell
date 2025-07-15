const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const build_config = @import("../../../build_config.zig");
const apprt = @import("../../../apprt.zig");
const CoreApp = @import("../../../App.zig");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.gtk);

/// The primary entrypoint for the Ghostty GTK application.
///
/// This requires a `ghostty.App` and `ghostty.Config` and takes
/// care of the rest. Call `run` to run the application to completion.
pub const GhosttyApplication = extern struct {
    /// This type creates a new GObject class. Since the Application is
    /// the primary entrypoint I'm going to use this as a place to document
    /// how this all works and where you can find resources for it, but
    /// this applies to any other GObject class within this apprt.
    ///
    /// The various fields (parent_instance) and constants (Parent,
    /// getGObjectType, etc.) are mandatory "interfaces" for zig-gobject
    /// to create a GObject class.
    ///
    /// I found these to be the best resources:
    ///
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/extensions/gobject2.zig
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/example/src/custom_class.zig
    ///
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Application;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The libghostty App instance.
        core_app: *CoreApp,

        /// The configuration for the application.
        config: *Config,

        /// This is set to false internally when the event loop
        /// should exit and the application should quit. This must
        /// only be set by the main loop thread.
        running: bool = false,

        var offset: c_int = 0;
    };

    /// Creates a new GhosttyApplication instance.
    ///
    /// Takes ownership of the `config` argument.
    pub fn new(core_app: *CoreApp, config: *Config) *Self {
        const single_instance = switch (config.@"gtk-single-instance") {
            .true => true,
            .false => false,
            .desktop => switch (config.@"launched-from".?) {
                .desktop, .systemd, .dbus => true,
                .cli => false,
            },
        };

        // Setup the flags for our application.
        const app_flags: gio.ApplicationFlags = app_flags: {
            var flags: gio.ApplicationFlags = .flags_default_flags;
            if (!single_instance) flags.non_unique = true;
            break :app_flags flags;
        };

        // Our app ID determines uniqueness and maps to our desktop file.
        // We append "-debug" to the ID if we're in debug mode so that we
        // can develop Ghostty in Ghostty.
        const app_id: [:0]const u8 = app_id: {
            if (config.class) |class| {
                if (gio.Application.idIsValid(class) != 0) {
                    break :app_id class;
                } else {
                    log.warn("invalid 'class' in config, ignoring", .{});
                }
            }

            const default_id = comptime build_config.bundle_id;
            break :app_id if (builtin.mode == .Debug) default_id ++ "-debug" else default_id;
        };

        // Create our GTK Application which encapsulates our process.
        log.debug("creating GTK application id={s} single-instance={}", .{
            app_id,
            single_instance,
        });

        const self = gobject.ext.newInstance(Self, .{
            .application_id = app_id.ptr,
            .flags = app_flags,
        });

        const priv = self.private();
        priv.core_app = core_app;
        priv.config = config;

        return self;
    }

    /// Force deinitialize the application.
    ///
    /// Normally in a GObject lifecycle, this would be called by the
    /// finalizer. But applications are never fully unreferenced so this
    /// ensures that our memory is cleaned up properly.
    pub fn deinit(self: *Self) void {
        const alloc = self.allocator();
        const priv = self.private();
        priv.config.deinit();
        alloc.destroy(priv.config);
    }

    /// Run the application. This is a replacement for `gio.Application.run`
    /// because we want more tight control over our event loop so we can
    /// integrate it with libghostty.
    pub fn run(self: *Self, rt_app: *apprt.gtk_ng.App) !void {
        // Based on the actual `gio.Application.run` implementation:
        // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533

        // Acquire the default context for the application
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;

        // The final cleanup that is always required at the end of running.
        defer {
            // Sync any remaining settings
            gio.Settings.sync();

            // Clear out the event loop, don't block.
            while (glib.MainContext.iteration(ctx, 0) != 0) {}

            // Release the context so something else can use it.
            defer glib.MainContext.release(ctx);
        }

        // Register the application
        var err_: ?*glib.Error = null;
        if (self.as(gio.Application).register(
            null,
            &err_,
        ) == 0) {
            if (err_) |err| {
                defer err.free();
                log.warn(
                    "error registering application: {s}",
                    .{err.f_message orelse "(unknown)"},
                );
            }

            return error.ApplicationRegisterFailed;
        }
        assert(err_ == null);

        // This just calls the `activate` signal but its part of the normal startup
        // routine so we just call it, but only if the config allows it (this allows
        // for launching Ghostty in the "background" without immediately opening
        // a window). An initial window will not be immediately created if we were
        // launched by D-Bus activation or systemd.  D-Bus activation will send it's
        // own `activate` or `new-window` signal later.
        //
        // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
        const priv = self.private();
        const config = priv.config;
        if (config.@"initial-window") switch (config.@"launched-from".?) {
            .desktop, .cli => self.as(gio.Application).activate(),
            .dbus, .systemd => {},
        };

        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running and
        // our "activate" call above will open a window.
        if (self.as(gio.Application).getIsRemote() != 0) {
            log.debug(
                "application is remote, exiting run loop after activation",
                .{},
            );
            return;
        }

        priv.running = true;
        while (priv.running) {
            _ = glib.MainContext.iteration(ctx, 1);

            // Tick the core Ghostty terminal app
            try priv.core_app.tick(rt_app);

            // Check if we must quit based on the current state.
            const must_quit = q: {
                // If we are configured to always stay running, don't quit.
                if (!config.@"quit-after-last-window-closed") break :q false;

                // If the quit timer has expired, quit.
                // if (self.quit_timer == .expired) break :q true;

                // There's no quit timer running, or it hasn't expired, don't quit.
                break :q false;
            };

            if (must_quit) {
                //self.quit();
                priv.running = false;
            }
        }
    }

    pub fn as(app: *Self, comptime T: type) *T {
        return gobject.ext.as(T, app);
    }

    pub fn unref(self: *Self) void {
        gobject.Object.unref(self.as(gobject.Object));
    }

    fn private(self: *GhosttyApplication) *Private {
        return gobject.ext.impl_helpers.getPrivate(
            self,
            Private,
            Private.offset,
        );
    }

    fn startup(self: *GhosttyApplication) callconv(.C) void {
        // This is where we would initialize the application, but we
        // do that in the `run` method instead.
        log.debug("GhosttyApplication started", .{});

        gio.Application.virtual_methods.startup.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn activate(self: *GhosttyApplication) callconv(.C) void {
        // This is called when the application is activated, but we
        // don't need to do anything here since we handle activation
        // in the `run` method.
        log.debug("GhosttyApplication activated", .{});

        // Call the parent activate method.
        gio.Application.virtual_methods.activate.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *GhosttyApplication) callconv(.C) void {
        self.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn allocator(self: *GhosttyApplication) std.mem.Allocator {
        return self.private().core_app.alloc;
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.C) void {
            gio.Application.virtual_methods.activate.implement(class, &activate);
            gio.Application.virtual_methods.startup.implement(class, &startup);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
