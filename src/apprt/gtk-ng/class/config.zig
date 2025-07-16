const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.gtk_ghostty_config);

/// Wraps a `Ghostty.Config` object in a GObject so it can be reference
/// counted. When this object is freed, the underlying config is also freed.
///
/// It is highly recommended to NOT take a reference to this object,
/// since configuration takes up a lot of memory (relatively). Instead,
/// receivers of this should usually create a `DerivedConfig` struct from
/// this, copy any memory they require, and own that structure instead.
///
/// This can also expose helpers to access configuration in ways that
/// may be more egonomic to GTK primitives.
pub const GhosttyConfig = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        config: Config,

        var offset: c_int = 0;
    };

    /// Create a new GhosttyConfig from a loaded configuration.
    ///
    /// This clones the given configuration, so it is safe for the
    /// caller to free the original configuration after this call.
    pub fn new(alloc: Allocator, config: *const Config) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const priv = self.private();
        priv.config = try config.clone(alloc);

        return self;
    }

    /// Get the wrapped configuration. It's unsafe to store this or access
    /// it in any way that may live beyond the lifetime of this object.
    pub fn get(self: *Self) *const Config {
        return &self.private().config;
    }

    fn finalize(self: *Self) callconv(.C) void {
        self.private().config.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    pub fn ref(self: *Self) *Self {
        return @ptrCast(@alignCast(gobject.Object.ref(self.as(gobject.Object))));
    }

    pub fn unref(self: *Self) void {
        gobject.Object.unref(self.as(gobject.Object));
    }

    fn private(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(
            self,
            Private,
            Private.offset,
        );
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.C) void {
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};

// This test verifies our memory management works as expected. Since
// we use the testing allocator any leaks are detected.
test "GhosttyConfig" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    const obj: *GhosttyConfig = try .new(alloc, &config);
    obj.unref();
}
