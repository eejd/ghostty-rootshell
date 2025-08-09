const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const Surface = @import("surface.zig").Surface;

const log = std.log.scoped(.gtk_ghostty_split_tree);

pub const SplitTree = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTree",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const @"has-surfaces" = struct {
            pub const name = "has-surfaces";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getHasSurfaces,
                        },
                    ),
                },
            );
        };

        pub const tree = struct {
            pub const name = "tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = .{
                        .getter = getTreeValue,
                        .setter = setTreeValue,
                    },
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tree property has changed, with access
        /// to the previous and new values.
        pub const changed = struct {
            pub const name = "changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ ?*const Surface.Tree, ?*const Surface.Tree },
                void,
            );
        };
    };

    const Private = struct {
        /// The tree datastructure containing all of our surface views.
        tree: ?*Surface.Tree,

        // Template bindings
        tree_bin: *adw.Bin,

        /// Last focused surface in the tree. We need this to handle various
        /// tree change states.
        last_focused: WeakRef(Surface) = .{},

        /// The source that we use to rebuild the tree. This is also
        /// used to debounce updates.
        rebuild_source: ?c_uint = null,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Initialize our actions
        self.initActions();
    }

    fn initActions(self: *Self) void {
        // The set of actions. Each action has (in order):
        // [0] The action name
        // [1] The callback function
        // [2] The glib.VariantType of the parameter
        //
        // For action names:
        // https://docs.gtk.org/gio/type_func.Action.name_is_valid.html
        const actions = .{
            // All of these will eventually take a target surface parameter.
            // For now all our targets originate from the focused surface.
            .{ "new-left", actionNewLeft, null },
            .{ "new-right", actionNewRight, null },
            .{ "new-up", actionNewUp, null },
            .{ "new-down", actionNewDown, null },
        };

        // We need to collect our actions into a group since we're just
        // a plain widget that doesn't implement ActionGroup directly.
        const group = gio.SimpleActionGroup.new();
        errdefer group.unref();
        const map = group.as(gio.ActionMap);
        inline for (actions) |entry| {
            const action = gio.SimpleAction.new(
                entry[0],
                entry[2],
            );
            defer action.unref();
            _ = gio.SimpleAction.signals.activate.connect(
                action,
                *Self,
                entry[1],
                self,
                .{},
            );
            map.addAction(action.as(gio.Action));
        }

        self.as(gtk.Widget).insertActionGroup(
            "split-tree",
            group.as(gio.ActionGroup),
        );
    }

    /// Create a new split in the given direction from the currently
    /// active surface.
    ///
    /// If the tree is empty this will create a new tree with a new surface
    /// and ignore the direction.
    ///
    /// The parent will be used as the parent of the surface regardless of
    /// if that parent is in this split tree or not. This allows inheriting
    /// surface properties from anywhere.
    pub fn newSplit(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        parent_: ?*Surface,
    ) Allocator.Error!void {
        const alloc = Application.default().allocator();

        // Create our new surface.
        const surface: *Surface = .new();
        defer surface.unref();
        _ = surface.refSink();

        // Inherit properly if we were asked to.
        if (parent_) |p| {
            if (p.core()) |core| {
                surface.setParent(core);
            }
        }

        // Create our tree
        var single_tree = try Surface.Tree.init(alloc, surface);
        defer single_tree.deinit();

        // We want to move our focus to the new surface no matter what.
        // But we need to be careful to restore state if we fail.
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref(); // unref strong ref from get
        self.private().last_focused.set(surface);
        errdefer self.private().last_focused.set(old_last_focused);

        // If we have no tree yet, then this becomes our tree and we're done.
        const old_tree = self.getTree() orelse {
            self.setTree(&single_tree);
            return;
        };

        // The handle we create the split relative to. Today this is the active
        // surface but this might be the handle of the given parent if we want.
        const handle = self.getActiveSurfaceHandle() orelse 0;

        // Create our split!
        var new_tree = try old_tree.split(
            alloc,
            handle,
            direction,
            &single_tree,
        );
        defer new_tree.deinit();
        log.debug(
            "new split at={} direction={} old_tree={} new_tree={}",
            .{ handle, direction, old_tree, &new_tree },
        );

        // Replace our tree
        self.setTree(&new_tree);

        // Focus our new surface
        surface.grabFocus();
    }

    fn disconnectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    fn connectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = Surface.signals.@"close-request".connect(
                surface,
                *Self,
                surfaceCloseRequest,
                self,
                .{},
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceFocused,
                self,
                .{ .detail = "focused" },
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tree = self.getTree() orelse return null;
        const handle = self.getActiveSurfaceHandle() orelse return null;
        return tree.nodes[handle].leaf;
    }

    fn getActiveSurfaceHandle(self: *Self) ?Surface.Tree.Node.Handle {
        const tree = self.getTree() orelse return null;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.getFocused()) return entry.handle;
        }

        return null;
    }

    /// Returns the last focused surface in the tree.
    pub fn getLastFocusedSurface(self: *Self) ?*Surface {
        const surface = self.private().last_focused.get() orelse return null;
        // We unref because get() refs the surface. We don't use the weakref
        // in a multi-threaded context so this is safe.
        surface.unref();
        return surface;
    }

    pub fn getHasSurfaces(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return !tree.isEmpty();
    }

    /// Get the tree data model that we're showing in this widget. This
    /// does not clone the tree.
    pub fn getTree(self: *Self) ?*Surface.Tree {
        return self.private().tree;
    }

    /// Set the tree data model that we're showing in this widget. This
    /// will clone the given tree.
    pub fn setTree(self: *Self, tree: ?*const Surface.Tree) void {
        const priv = self.private();

        // Emit the signal so that handlers can witness both the before and
        // after values of the tree.
        signals.changed.impl.emit(
            self,
            null,
            .{ priv.tree, tree },
            null,
        );

        if (priv.tree) |old_tree| {
            self.disconnectSurfaceHandlers();
            ext.boxedFree(Surface.Tree, old_tree);
            priv.tree = null;
        }

        if (tree) |new_tree| {
            priv.tree = ext.boxedCopy(Surface.Tree, new_tree);
            self.connectSurfaceHandlers();
        }

        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
    }

    fn getTreeValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().tree,
        );
    }

    fn setTreeValue(self: *Self, value: *const gobject.Value) void {
        self.setTree(gobject.ext.Value.get(
            value,
            ?*Surface.Tree,
        ));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.last_focused.set(null);
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
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

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tree) |tree| {
            ext.boxedFree(Surface.Tree, tree);
            priv.tree = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    pub fn actionNewLeft(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;
        self.newSplit(
            .left,
            self.getActiveSurface(),
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }

    pub fn actionNewRight(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;
        self.newSplit(
            .right,
            self.getActiveSurface(),
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }

    pub fn actionNewUp(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;
        self.newSplit(
            .up,
            self.getActiveSurface(),
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }

    pub fn actionNewDown(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;
        self.newSplit(
            .down,
            self.getActiveSurface(),
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }

    fn surfaceCloseRequest(
        surface: *Surface,
        scope: *const Surface.CloseScope,
        self: *Self,
    ) callconv(.c) void {
        switch (scope.*) {
            // Handled upstream... this will probably go away for widget
            // actions eventually.
            .window, .tab => return,

            // Remove the surface from the tree.
            .surface => {
                // TODO: close confirmation
                // TODO: invalid free on final close

                // Find the surface in the tree.
                const tree = self.getTree() orelse return;
                const handle: Surface.Tree.Node.Handle = handle: {
                    var it = tree.iterator();
                    while (it.next()) |entry| {
                        if (entry.view == surface) break :handle entry.handle;
                    }

                    return;
                };

                // Remove it from the tree.
                var new_tree = tree.remove(
                    Application.default().allocator(),
                    handle,
                ) catch |err| {
                    log.warn("unable to remove surface from tree: {}", .{err});
                    return;
                };
                defer new_tree.deinit();
                self.setTree(&new_tree);
            },
        }
    }

    fn propSurfaceFocused(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We never CLEAR our last_focused because the property is specifically
        // the last focused surface. We let the weakref clear itself when
        // the surface is destroyed.
        if (!surface.getFocused()) return;
        self.private().last_focused.set(surface);

        // Our active surface probably changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn propTree(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();

        // We need to reset our tree and create the new widget hierarchy
        // on two separate event loop ticks to allow GTK to properly relayout
        // our widgets.
        //
        // Doing this all at once will cause strange rendering glitches,
        // the glarea to be gone forever (but not deallocated), etc. I think
        // this is probably a bug in GTK we can minimize and report later.
        //
        // Using an idle callback also allows us to debounce updates.
        priv.tree_bin.setChild(null);
        if (priv.rebuild_source == null) priv.rebuild_source = glib.idleAdd(
            onRebuild,
            self,
        );

        // Dependent properties
        self.as(gobject.Object).notifyByPspec(properties.@"has-surfaces".impl.param_spec);
    }

    fn onRebuild(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always mark our rebuild source as null since we're done.
        const priv = self.private();
        priv.rebuild_source = null;

        // Rebuild our tree
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (!tree.isEmpty()) {
            priv.tree_bin.setChild(self.buildTree(tree, 0));
        }

        // If we have a last focused surface, we need to refocus it, because
        // during the frame between setting the bin to null and rebuilding,
        // GTK will reset our focus state (as it should!)
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            v.grabFocus();
        }

        // Our active surface may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);

        return 0;
    }

    /// Builds the widget tree associated with a surface split tree.
    ///
    /// The final returned widget is expected to be a floating reference,
    /// ready to be attached to a parent widget.
    fn buildTree(
        self: *Self,
        tree: *const Surface.Tree,
        current: Surface.Tree.Node.Handle,
    ) *gtk.Widget {
        return switch (tree.nodes[current]) {
            .leaf => |v| v.as(gtk.Widget),
            .split => |s| SplitTreeSplit.new(
                current,
                &s,
                self.buildTree(tree, s.left),
                self.buildTree(tree, s.right),
            ).as(gtk.Widget),
        };
    }

    //---------------------------------------------------------------
    // Class

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.@"has-surfaces".impl,
                properties.tree.impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tree_bin", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_tree", &propTree);

            // Signals
            signals.changed.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// This is an internal-only widget that represents a split in the
/// split tree. This is a wrapper around gtk.Paned that allows us to handle
/// ratio (0 to 1) based positioning of the split, and also allows us to
/// write back the updated ratio to the split tree when the user manually
/// adjusts the split position.
///
/// Since this is internal, it expects to be nested within a SplitTree and
/// will use `getAncestor` to find the SplitTree it belongs to.
///
/// This is an _immutable_ widget. It isn't meant to be updated after
/// creation. As such, there are no properties or APIs to change the split,
/// access the paned, etc.
const SplitTreeSplit = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTreeSplit",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The handle of the node in the tree that this split represents.
        /// Assumed to be correct.
        handle: Surface.Tree.Node.Handle,

        /// Source to handle repositioning the split when properties change.
        idle: ?c_uint = null,

        // Template bindings
        paned: *gtk.Paned,

        pub var offset: c_int = 0;
    };

    /// Create a new split.
    ///
    /// The reason we don't use GObject properties here is because this is
    /// an immutable widget and we don't want to deal with the overhead of
    /// all the boilerplate for properties, signals, bindings, etc.
    pub fn new(
        handle: Surface.Tree.Node.Handle,
        split: *const Surface.Tree.Split,
        start_child: *gtk.Widget,
        end_child: *gtk.Widget,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.handle = handle;

        // Setup our paned fields
        const paned = priv.paned;
        paned.setStartChild(start_child);
        paned.setEndChild(end_child);
        paned.as(gtk.Orientable).setOrientation(switch (split.layout) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        });

        // Signals and so on are setup in the template.

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        if (priv.idle == null) priv.idle = glib.idleAdd(
            onIdle,
            self,
        );
    }

    fn onIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        const paned = priv.paned;

        // Our idle source is always over
        priv.idle = null;

        // Get our split. This is the most dangerous part of this entire
        // widget. We assume that this widget is always a child of a
        // SplitTree, we assume that our handle is valid, and we assume
        // the handle is always a split node.
        const split_tree = ext.getAncestor(
            SplitTree,
            self.as(gtk.Widget),
        ) orelse return 0;
        const tree = split_tree.getTree() orelse return 0;
        const split: *const Surface.Tree.Split = &tree.nodes[priv.handle].split;

        // Current, min, and max positions as pixels.
        const pos = paned.getPosition();
        const min = min: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "min-position",
                &val,
            );
            break :min gobject.ext.Value.get(&val, c_int);
        };
        const max = max: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "max-position",
                &val,
            );
            break :max gobject.ext.Value.get(&val, c_int);
        };
        const pos_set: bool = max: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "position-set",
                &val,
            );
            break :max gobject.ext.Value.get(&val, c_int) != 0;
        };

        // We don't actually use min, but we don't expect this to ever
        // be non-zero, so let's add an assert to ensure that.
        assert(min == 0);

        // If our max is zero then we can't do any math. I don't know
        // if this is possible but I suspect it can be if you make a nested
        // split completely minimized.
        if (max == 0) return 0;

        // Determine our current ratio.
        const current_ratio: f64 = ratio: {
            const pos_f64: f64 = @floatFromInt(pos);
            const max_f64: f64 = @floatFromInt(max);
            break :ratio pos_f64 / max_f64;
        };
        const desired_ratio: f64 = @floatCast(split.ratio);

        // If our ratio is close enough to our desired ratio, then
        // we ignore the update. This is to avoid constant split updates
        // for lossy floating point math.
        if (std.math.approxEqAbs(
            f64,
            current_ratio,
            desired_ratio,
            0.001,
        )) {
            return 0;
        }

        // If we're out of bounds, then we need to either set the position
        // to what we expect OR update our expected ratio.

        // If we've never set the position, then we set it to the desired.
        if (!pos_set) {
            const desired_pos: c_int = desired_pos: {
                const max_f64: f64 = @floatFromInt(max);
                break :desired_pos @intFromFloat(@round(max_f64 * desired_ratio));
            };
            paned.setPosition(desired_pos);
            return 0;
        }

        // If we've set the position, then this is a manual human update
        // and we need to write our update back to the tree.
        tree.resizeInPlace(priv.handle, @floatCast(current_ratio));

        return 0;
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn propPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    fn propMaxPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    fn propMinPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.idle) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove idle source", .{});
            }
            priv.idle = null;
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

    fn finalize(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
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

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree-split",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("paned", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_max_position", &propMaxPosition);
            class.bindTemplateCallback("notify_min_position", &propMinPosition);
            class.bindTemplateCallback("notify_position", &propPosition);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
