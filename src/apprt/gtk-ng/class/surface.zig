const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const input = @import("../../../input.zig");
const internal_os = @import("../../../os/main.zig");
const renderer = @import("../../../renderer.zig");
const CoreSurface = @import("../../../Surface.zig");
const gresource = @import("../build/gresource.zig");
const adw_version = @import("../adw_version.zig");
const gtk_key = @import("../key.zig");
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
        gl_area: *gtk.GLArea = undefined,

        /// The apprt Surface.
        rt_surface: ApprtSurface = undefined,

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

        /// Cached metrics for libghostty callbacks
        size: apprt.SurfaceSize,
        cursor_pos: apprt.CursorPos,

        /// Various input method state. All related to key input.
        in_keyevent: IMKeyEvent = .false,
        im_context: ?*gtk.IMMulticontext = null,
        im_composing: bool = false,
        im_buf: [128]u8 = undefined,
        im_len: u7 = 0,

        /// True when we have a precision scroll in progress
        precision_scroll: bool = false,

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
    pub fn redraw(self: *Self) void {
        const priv = self.private();
        priv.gl_area.queueRender();
    }

    /// Key press event (press or release).
    ///
    /// At a high level, we want to construct an `input.KeyEvent` and
    /// pass that to `keyCallback`. At a low level, this is more complicated
    /// than it appears because we need to construct all of this information
    /// and its not given to us.
    ///
    /// For all events, we run the GdkEvent through the input method context.
    /// This allows the input method to capture the event and trigger
    /// callbacks such as preedit, commit, etc.
    ///
    /// There are a couple important aspects to the prior paragraph: we must
    /// send ALL events through the input method context. This is because
    /// input methods use both key press and key release events to determine
    /// the state of the input method. For example, fcitx uses key release
    /// events on modifiers (i.e. ctrl+shift) to switch the input method.
    ///
    /// We set some state to note we're in a key event (self.in_keyevent)
    /// because some of the input method callbacks change behavior based on
    /// this state. For example, we don't want to send character events
    /// like "a" via the input "commit" event if we're actively processing
    /// a keypress because we'd lose access to the keycode information.
    /// However, a "commit" event may still happen outside of a keypress
    /// event from e.g. a tablet or on-screen keyboard.
    ///
    /// Finally, we take all of the information in order to determine if we have
    /// a unicode character or if we have to map the keyval to a code to
    /// get the underlying logical key, etc.
    ///
    /// Then we can emit the keyCallback.
    pub fn keyEvent(
        self: *Surface,
        action: input.Action,
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        gtk_mods: gdk.ModifierType,
    ) bool {
        log.warn("keyEvent action={}", .{action});

        _ = self;
        _ = ec_key;
        _ = keyval;
        _ = keycode;
        _ = gtk_mods;
        return false;
    }

    /// Scale x/y by the GDK device scale.
    fn scaledCoordinates(
        self: *Self,
        x: f64,
        y: f64,
    ) struct { x: f64, y: f64 } {
        const gl_area = self.private().gl_area;
        const scale_factor: f64 = @floatFromInt(
            gl_area.as(gtk.Widget).getScaleFactor(),
        );

        return .{
            .x = x * scale_factor,
            .y = y * scale_factor,
        };
    }

    //---------------------------------------------------------------
    // Libghostty Callbacks

    pub fn getContentScale(self: *Self) apprt.ContentScale {
        const priv = self.private();
        const gl_area = priv.gl_area;

        const gtk_scale: f32 = scale: {
            const widget = gl_area.as(gtk.Widget);
            // Future: detect GTK version 4.12+ and use gdk_surface_get_scale so we
            // can support fractional scaling.
            const scale = widget.getScaleFactor();
            if (scale <= 0) {
                log.warn("gtk_widget_get_scale_factor returned a non-positive number: {}", .{scale});
                break :scale 1.0;
            }
            break :scale @floatFromInt(scale);
        };

        // Also scale using font-specific DPI, which is often exposed to the user
        // via DE accessibility settings (see https://docs.gtk.org/gtk4/class.Settings.html).
        const xft_dpi_scale = xft_scale: {
            // gtk-xft-dpi is font DPI multiplied by 1024. See
            // https://docs.gtk.org/gtk4/property.Settings.gtk-xft-dpi.html
            const settings = gtk.Settings.getDefault() orelse break :xft_scale 1.0;
            var value = std.mem.zeroes(gobject.Value);
            defer value.unset();
            _ = value.init(gobject.ext.typeFor(c_int));
            settings.as(gobject.Object).getProperty("gtk-xft-dpi", &value);
            const gtk_xft_dpi = value.getInt();

            // Use a value of 1.0 for the XFT DPI scale if the setting is <= 0
            // See:
            // https://gitlab.gnome.org/GNOME/libadwaita/-/commit/a7738a4d269bfdf4d8d5429ca73ccdd9b2450421
            // https://gitlab.gnome.org/GNOME/libadwaita/-/commit/9759d3fd81129608dd78116001928f2aed974ead
            if (gtk_xft_dpi <= 0) {
                log.warn("gtk-xft-dpi was not set, using default value", .{});
                break :xft_scale 1.0;
            }

            // As noted above gtk-xft-dpi is multiplied by 1024, so we divide by
            // 1024, then divide by the default value (96) to derive a scale. Note
            // gtk-xft-dpi can be fractional, so we use floating point math here.
            const xft_dpi: f32 = @as(f32, @floatFromInt(gtk_xft_dpi)) / 1024.0;
            break :xft_scale xft_dpi / 96.0;
        };

        const scale = gtk_scale * xft_dpi_scale;
        return .{ .x = scale, .y = scale };
    }

    pub fn getSize(self: *Self) apprt.SurfaceSize {
        return self.private().size;
    }

    pub fn getCursorPos(self: *Self) apprt.CursorPos {
        return self.private().cursor_pos;
    }

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

        // Initialize some private fields so they aren't undefined
        priv.rt_surface = .{ .surface = self };
        priv.precision_scroll = false;
        priv.cursor_pos = .{ .x = 0, .y = 0 };
        priv.size = .{
            // Funky numbers on purpose so they stand out if for some reason
            // our size doesn't get properly set.
            .width = 111,
            .height = 111,
        };

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        const self_widget = self.as(gtk.Widget);

        // Setup our event controllers to get input events
        const ec_key = gtk.EventControllerKey.new();
        errdefer ec_key.unref();
        self_widget.addController(ec_key.as(gtk.EventController));
        errdefer self_widget.removeController(ec_key.as(gtk.EventController));
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            ec_key,
            *Self,
            ecKeyPressed,
            self,
            .{},
        );
        _ = gtk.EventControllerKey.signals.key_released.connect(
            ec_key,
            *Self,
            ecKeyReleased,
            self,
            .{},
        );

        // Focus controller will tell us about focus enter/exit events
        const ec_focus = gtk.EventControllerFocus.new();
        errdefer ec_focus.unref();
        self_widget.addController(ec_focus.as(gtk.EventController));
        errdefer self_widget.removeController(ec_focus.as(gtk.EventController));
        _ = gtk.EventControllerFocus.signals.enter.connect(
            ec_focus,
            *Self,
            ecFocusEnter,
            self,
            .{},
        );
        _ = gtk.EventControllerFocus.signals.leave.connect(
            ec_focus,
            *Self,
            ecFocusLeave,
            self,
            .{},
        );

        // Clicks
        const gesture_click = gtk.GestureClick.new();
        errdefer gesture_click.unref();
        gesture_click.as(gtk.GestureSingle).setButton(0);
        self_widget.addController(gesture_click.as(gtk.EventController));
        errdefer self_widget.removeController(gesture_click.as(gtk.EventController));
        _ = gtk.GestureClick.signals.pressed.connect(
            gesture_click,
            *Self,
            gcMouseDown,
            self,
            .{},
        );
        _ = gtk.GestureClick.signals.released.connect(
            gesture_click,
            *Self,
            gcMouseUp,
            self,
            .{},
        );

        // Mouse movement
        const ec_motion = gtk.EventControllerMotion.new();
        errdefer ec_motion.unref();
        self_widget.addController(ec_motion.as(gtk.EventController));
        errdefer self_widget.removeController(ec_motion.as(gtk.EventController));
        _ = gtk.EventControllerMotion.signals.motion.connect(
            ec_motion,
            *Self,
            ecMouseMotion,
            self,
            .{},
        );
        _ = gtk.EventControllerMotion.signals.leave.connect(
            ec_motion,
            *Self,
            ecMouseLeave,
            self,
            .{},
        );

        // Scroll
        const ec_scroll = gtk.EventControllerScroll.new(.flags_both_axes);
        errdefer ec_scroll.unref();
        self_widget.addController(ec_scroll.as(gtk.EventController));
        errdefer self_widget.removeController(ec_scroll.as(gtk.EventController));
        _ = gtk.EventControllerScroll.signals.scroll.connect(
            ec_scroll,
            *Self,
            ecMouseScroll,
            self,
            .{},
        );
        _ = gtk.EventControllerScroll.signals.scroll_begin.connect(
            ec_scroll,
            *Self,
            ecMouseScrollPrecisionBegin,
            self,
            .{},
        );
        _ = gtk.EventControllerScroll.signals.scroll_end.connect(
            ec_scroll,
            *Self,
            ecMouseScrollPrecisionEnd,
            self,
            .{},
        );

        // Setup our input method state
        const im_context = gtk.IMMulticontext.new();
        priv.im_context = im_context;
        priv.in_keyevent = .false;
        priv.im_composing = false;
        priv.im_len = 0;
        _ = gtk.IMContext.signals.preedit_start.connect(
            im_context,
            *Self,
            imPreeditStart,
            self,
            .{},
        );
        _ = gtk.IMContext.signals.preedit_changed.connect(
            im_context,
            *Self,
            imPreeditChanged,
            self,
            .{},
        );
        _ = gtk.IMContext.signals.preedit_end.connect(
            im_context,
            *Self,
            imPreeditEnd,
            self,
            .{},
        );
        _ = gtk.IMContext.signals.commit.connect(
            im_context,
            *Self,
            imCommit,
            self,
            .{},
        );

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
        _ = gtk.GLArea.signals.render.connect(
            gl_area,
            *Self,
            glareaRender,
            self,
            .{},
        );
        _ = gtk.GLArea.signals.resize.connect(
            gl_area,
            *Self,
            glareaResize,
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
        if (priv.im_context) |v| {
            v.unref();
            priv.im_context = null;
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
            // Remove ourselves from the list of known surfaces in the app.
            // We do this before deinit in case a callback triggers
            // searching for this surface.
            Application.default().core().deleteSurface(self.rt());

            // Deinit the surface
            v.deinit();
            const alloc = Application.default().allocator();
            alloc.destroy(v);

            priv.core_surface = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn ecKeyPressed(
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        return @intFromBool(self.keyEvent(
            .press,
            ec_key,
            keyval,
            keycode,
            gtk_mods,
        ));
    }

    fn ecKeyReleased(
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) void {
        _ = self.keyEvent(
            .release,
            ec_key,
            keyval,
            keycode,
            state,
        );
    }

    fn ecFocusEnter(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.im_context) |im_context| {
            im_context.as(gtk.IMContext).focusIn();
        }

        if (priv.core_surface) |surface| {
            surface.focusCallback(true) catch |err| {
                log.warn("error in focus callback err={}", .{err});
            };
        }
    }

    fn ecFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.im_context) |im_context| {
            im_context.as(gtk.IMContext).focusOut();
        }

        if (priv.core_surface) |surface| {
            surface.focusCallback(false) catch |err| {
                log.warn("error in focus callback err={}", .{err});
            };
        }
    }

    fn gcMouseDown(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;

        // If we don't have focus, grab it.
        const priv = self.private();
        const gl_area_widget = priv.gl_area.as(gtk.Widget);
        if (gl_area_widget.hasFocus() == 0) {
            _ = gl_area_widget.grabFocus();
        }

        // Report the event
        const consumed = if (priv.core_surface) |surface| consumed: {
            const gtk_mods = event.getModifierState();
            const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());
            const mods = gtk_key.translateMods(gtk_mods);
            break :consumed surface.mouseButtonCallback(
                .press,
                button,
                mods,
            ) catch |err| err: {
                log.warn("error in key callback err={}", .{err});
                break :err false;
            };
        } else false;

        // TODO: context menu
        _ = consumed;
        _ = x;
        _ = y;
    }

    fn gcMouseUp(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;

        const priv = self.private();
        if (priv.core_surface) |surface| {
            const gtk_mods = event.getModifierState();
            const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());
            const mods = gtk_key.translateMods(gtk_mods);
            _ = surface.mouseButtonCallback(
                .release,
                button,
                mods,
            ) catch |err| {
                log.warn("error in key callback err={}", .{err});
                return;
            };
        }
    }

    fn ecMouseMotion(
        ec: *gtk.EventControllerMotion,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = ec.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();

        const scaled = self.scaledCoordinates(x, y);
        const pos: apprt.CursorPos = .{
            .x = @floatCast(scaled.x),
            .y = @floatCast(scaled.y),
        };

        // There seem to be at least two cases where GTK issues a mouse motion
        // event without the cursor actually moving:
        // 1. GLArea is resized under the mouse. This has the unfortunate
        //    side effect of causing focus to potentially change when
        //    `focus-follows-mouse` is enabled.
        // 2. The window title is updated. This can cause the mouse to unhide
        //    incorrectly when hide-mouse-when-typing is enabled.
        // To prevent incorrect behavior, we'll only grab focus and
        // continue with callback logic if the cursor has actually moved.
        const is_cursor_still = @abs(priv.cursor_pos.x - pos.x) < 1 and
            @abs(priv.cursor_pos.y - pos.y) < 1;
        if (is_cursor_still) return;

        // If we don't have focus, and we want it, grab it.
        if (priv.config) |config| {
            const gl_area_widget = priv.gl_area.as(gtk.Widget);
            if (gl_area_widget.hasFocus() == 0 and
                config.get().@"focus-follows-mouse")
            {
                _ = gl_area_widget.grabFocus();
            }
        }

        // Our pos changed, update
        priv.cursor_pos = pos;

        // Notify the callback
        if (priv.core_surface) |surface| {
            const gtk_mods = event.getModifierState();
            const mods = gtk_key.translateMods(gtk_mods);
            surface.cursorPosCallback(priv.cursor_pos, mods) catch |err| {
                log.warn("error in cursor pos callback err={}", .{err});
            };
        }
    }

    fn ecMouseLeave(
        ec_motion: *gtk.EventControllerMotion,
        self: *Self,
    ) callconv(.c) void {
        const event = ec_motion.as(gtk.EventController).getCurrentEvent() orelse return;

        // Get our modifiers
        const priv = self.private();
        if (priv.core_surface) |surface| {
            // If we have a core surface then we can send the cursor pos
            // callback with an invalid position to indicate the mouse left.
            const gtk_mods = event.getModifierState();
            const mods = gtk_key.translateMods(gtk_mods);
            surface.cursorPosCallback(
                .{ .x = -1, .y = -1 },
                mods,
            ) catch |err| {
                log.warn("error in cursor pos callback err={}", .{err});
                return;
            };
        }
    }

    fn ecMouseScrollPrecisionBegin(
        _: *gtk.EventControllerScroll,
        self: *Self,
    ) callconv(.c) void {
        self.private().precision_scroll = true;
    }

    fn ecMouseScrollPrecisionEnd(
        _: *gtk.EventControllerScroll,
        self: *Self,
    ) callconv(.c) void {
        self.private().precision_scroll = false;
    }

    fn ecMouseScroll(
        _: *gtk.EventControllerScroll,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        if (priv.core_surface) |surface| {
            // Multiply precision scrolls by 10 to get a better response from
            // touchpad scrolling
            const multiplier: f64 = if (priv.precision_scroll) 10.0 else 1.0;
            const scroll_mods: input.ScrollMods = .{
                .precision = priv.precision_scroll,
            };

            const scaled = self.scaledCoordinates(x, y);
            surface.scrollCallback(
                // We invert because we apply natural scrolling to the values.
                // This behavior has existed for years without Linux users complaining
                // but I suspect we'll have to make this configurable in the future
                // or read a system setting.
                scaled.x * -1 * multiplier,
                scaled.y * -1 * multiplier,
                scroll_mods,
            ) catch |err| {
                log.warn("error in scroll callback err={}", .{err});
                return 0;
            };

            return 1;
        }

        return 0;
    }

    fn imPreeditStart(
        _: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        // log.warn("GTKIM: preedit start", .{});

        // Start our composing state for the input method and reset our
        // input buffer to empty.
        const priv = self.private();
        priv.im_composing = true;
        priv.im_len = 0;
    }

    fn imPreeditChanged(
        ctx: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Any preedit change should mark that we're composing. Its possible this
        // is false using fcitx5-hangul and typing "dkssud<space>" ("안녕"). The
        // second "s" results in a "commit" for "안" which sets composing to false,
        // but then immediately sends a preedit change for the next symbol. With
        // composing set to false we won't commit this text. Therefore, we must
        // ensure it is set here.
        priv.im_composing = true;

        // We can't set our preedit on our surface unless we're realized.
        // We do this now because we want to still keep our input method
        // state coherent.
        const surface = priv.core_surface orelse return;

        // Get our pre-edit string that we'll use to show the user.
        var buf: [*:0]u8 = undefined;
        ctx.as(gtk.IMContext).getPreeditString(
            &buf,
            null,
            null,
        );
        defer glib.free(buf);
        const str = std.mem.sliceTo(buf, 0);

        // Update our preedit state in Ghostty core
        // log.warn("GTKIM: preedit change str={s}", .{str});
        surface.preeditCallback(str) catch |err| {
            log.warn(
                "error in preedit callback err={}",
                .{err},
            );
        };
    }

    fn imPreeditEnd(
        _: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        // log.warn("GTKIM: preedit end", .{});

        // End our composing state for GTK, allowing us to commit the text.
        const priv = self.private();
        priv.im_composing = false;

        // End our preedit state in Ghostty core
        const surface = priv.core_surface orelse return;
        surface.preeditCallback(null) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
    }

    fn imCommit(
        _: *gtk.IMMulticontext,
        bytes: [*:0]u8,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const str = std.mem.sliceTo(bytes, 0);

        // log.debug("GTKIM: input commit composing={} keyevent={} str={s}", .{
        //     self.im_composing,
        //     self.in_keyevent,
        //     str,
        // });

        // We need to handle commit specially if we're in a key event.
        // Specifically, GTK will send us a commit event for basic key
        // encodings like "a" (on a US layout keyboard). We don't want
        // to treat this as IME committed text because we want to associate
        // it with a key event (i.e. "a" key press).
        switch (priv.in_keyevent) {
            // If we're not in a key event then this commit is from
            // some other source (i.e. on-screen keyboard, tablet, etc.)
            // and we want to commit the text to the core surface.
            .false => {},

            // If we're in a composing state and in a key event then this
            // key event is resulting in a commit of multiple keypresses
            // and we don't want to encode it alongside the keypress.
            .composing => {},

            // If we're not composing then this commit is just a normal
            // key encoding and we want our key event to handle it so
            // that Ghostty can be aware of the key event alongside
            // the text.
            .not_composing => {
                if (str.len > priv.im_buf.len) {
                    log.warn("not enough buffer space for input method commit", .{});
                    return;
                }

                // Copy our committed text to the buffer
                @memcpy(priv.im_buf[0..str.len], str);
                priv.im_len = @intCast(str.len);

                // log.debug("input commit len={}", .{priv.im_len});
                return;
            },
        }

        // If we reach this point from above it means we're composing OR
        // not in a keypress. In either case, we want to commit the text
        // given to us because that's what GTK is asking us to do. If we're
        // not in a keypress it means that this commit came via a non-keyboard
        // event (i.e. on-screen keyboard, tablet of some kind, etc.).

        // Committing ends composing state
        priv.im_composing = false;

        // We can't set our preedit on our surface unless we're realized.
        // We do this now because we want to still keep our input method
        // state coherent.
        if (priv.core_surface) |surface| {
            // End our preedit state. Well-behaved input methods do this for us
            // by triggering a preedit-end event but some do not (ibus 1.5.29).
            surface.preeditCallback(null) catch |err| {
                log.warn("error in preedit callback err={}", .{err});
            };

            // Send the text to the core surface, associated with no key (an
            // invalid key, which should produce no PTY encoding).
            _ = surface.keyCallback(.{
                .action = .press,
                .key = .unidentified,
                .mods = .{},
                .consumed_mods = .{},
                .composing = false,
                .utf8 = str,
            }) catch |err| {
                log.warn("error in key callback err={}", .{err});
            };
        }
    }

    fn glareaRealize(
        _: *gtk.GLArea,
        self: *Self,
    ) callconv(.c) void {
        log.debug("realize", .{});

        // Setup our core surface
        self.realizeSurface() catch |err| {
            log.warn("surface failed to realize err={}", .{err});
        };

        // Setup our input method. We do this here because this will
        // create a strong reference back to ourself and we want to be
        // able to release that in unrealize.
        if (self.private().im_context) |im_context| {
            im_context.as(gtk.IMContext).setClientWidget(self.as(gtk.Widget));
        }
    }

    fn glareaUnrealize(
        gl_area: *gtk.GLArea,
        self: *Self,
    ) callconv(.c) void {
        log.debug("unrealize", .{});

        // Notify our core surface
        const priv = self.private();
        if (priv.core_surface) |surface| {
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

        // Unset our input method
        if (priv.im_context) |im_context| {
            im_context.as(gtk.IMContext).setClientWidget(null);
        }
    }

    fn glareaRender(
        _: *gtk.GLArea,
        _: *gdk.GLContext,
        self: *Self,
    ) callconv(.c) c_int {
        // If we don't have a surface then we failed to initialize for
        // some reason and there's nothing to draw to the GLArea.
        const priv = self.private();
        const surface = priv.core_surface orelse return 1;

        surface.renderer.drawFrame(true) catch |err| {
            log.warn("failed to draw frame err={}", .{err});
            return 0;
        };

        return 1;
    }

    fn glareaResize(
        gl_area: *gtk.GLArea,
        width: c_int,
        height: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Some debug output to help understand what GTK is telling us.
        {
            const widget = gl_area.as(gtk.Widget);
            const scale_factor = widget.getScaleFactor();
            const window_scale_factor = scale: {
                const root = widget.getRoot() orelse break :scale 0;
                const gtk_native = root.as(gtk.Native);
                const gdk_surface = gtk_native.getSurface() orelse break :scale 0;
                break :scale gdk_surface.getScaleFactor();
            };

            log.debug("gl resize width={} height={} scale={} window_scale={}", .{
                width,
                height,
                scale_factor,
                window_scale_factor,
            });
        }

        // Store our cached size
        const priv = self.private();
        priv.size = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };

        // If our surface is realize, we send callbacks.
        if (priv.core_surface) |surface| {
            // We also update the content scale because there is no signal for
            // content scale change and it seems to trigger a resize event.
            surface.contentScaleCallback(self.getContentScale()) catch |err| {
                log.warn("error in content scale callback err={}", .{err});
            };

            surface.sizeCallback(priv.size) catch |err| {
                log.warn("error in size callback err={}", .{err});
            };
        }
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

/// The state of the key event while we're doing IM composition.
/// See gtkKeyPressed for detailed descriptions.
pub const IMKeyEvent = enum {
    /// Not in a key event.
    false,

    /// In a key event but im_composing was either true or false
    /// prior to the calling IME processing. This is important to
    /// work around different input methods calling commit and
    /// preedit end in a different order.
    composing,
    not_composing,
};

fn translateMouseButton(button: c_uint) input.MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .four,
        5 => .five,
        6 => .six,
        7 => .seven,
        8 => .eight,
        9 => .nine,
        10 => .ten,
        11 => .eleven,
        else => .unknown,
    };
}
