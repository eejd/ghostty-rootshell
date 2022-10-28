const std = @import("std");
const c = @import("c.zig");
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Object = struct {
    value: c.id,

    pub usingnamespace MsgSend(Object);

    pub fn fromId(id: anytype) Object {
        return .{ .value = @ptrCast(c.id, @alignCast(@alignOf(c.id), id)) };
    }

    /// Returns the class of an object.
    pub fn getClass(self: Object) ?objc.Class {
        return objc.Class{
            .value = c.object_getClass(self.value) orelse return null,
        };
    }

    /// Returns the class name of a given object.
    pub fn getClassName(self: Object) [:0]const u8 {
        return std.mem.sliceTo(c.object_getClassName(self.value), 0);
    }
};

test {
    const testing = std.testing;
    const NSObject = objc.Class.getClass("NSObject").?;

    // Should work with our wrappers
    const obj = NSObject.msgSend(objc.Object, objc.Sel.registerName("alloc"), .{});
    try testing.expect(obj.value != null);
    try testing.expectEqualStrings("NSObject", obj.getClassName());
    obj.msgSend(void, objc.sel("dealloc"), .{});
}
