//! This files contains all the GObject classes for the GTK apprt
//! along with helpers to work with them.

const glib = @import("glib");
const gobject = @import("gobject");

pub const Application = @import("class/application.zig").Application;
pub const Window = @import("class/window.zig").Window;
pub const Config = @import("class/config.zig").Config;

/// Unrefs the given GObject on the next event loop tick.
///
/// This works around an issue with zig-object where dynamically
/// generated gobjects in property getters can't unref themselves
/// normally: https://github.com/ianprime0509/zig-gobject/issues/108
pub fn unrefLater(obj: anytype) void {
    _ = glib.idleAdd((struct {
        fn callback(data_: ?*anyopaque) callconv(.c) c_int {
            const remove = @intFromBool(glib.SOURCE_REMOVE);
            const data = data_ orelse return remove;
            const object: *gobject.Object = @ptrCast(@alignCast(data));
            object.unref();
            return remove;
        }
    }).callback, obj.as(gobject.Object));
}
